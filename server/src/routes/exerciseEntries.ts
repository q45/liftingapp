import { Router } from "express";
import { pool } from "../db.js";
import {
    EXERCISE_ENTRY_COLUMNS,
    hydrateExercise,
    mapExerciseEntryRow,
    type ExerciseEntryRow,
} from "../mappers.js";
import {
    asyncHandler,
    HttpError,
    requireUserID,
    requireUUID,
} from "../middleware.js";
import { ExerciseEntrySchema, parse } from "../schemas.js";

const router = Router();

/** GET /exercise-entries/:id -- returns live rows only, hydrated with sets. */
router.get(
    "/exercise-entries/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const { rows } = await pool.query<ExerciseEntryRow>(
            `SELECT ${EXERCISE_ENTRY_COLUMNS}
             FROM exercise_entries
             WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
            [id, userID],
        );
        const row = rows[0];
        if (!row) throw new HttpError(404, `Exercise entry ${id} not found`);
        res.json(await hydrateExercise(pool, userID, row));
    }),
);

/** PUT /exercise-entries/:id -- shallow upsert with last-write-wins. */
router.put(
    "/exercise-entries/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const urlID = requireUUID(req.params.id);
        const dto = parse(ExerciseEntrySchema, req.body);
        if (dto.id !== urlID) {
            throw new HttpError(400, "URL id does not match body id");
        }

        // FK guard. The referenced session must exist, be live, AND
        // belong to the caller -- otherwise a user could attach their
        // exercise entries into another user's session.
        if (dto.sessionID) {
            const exists = await pool.query<{ id: string }>(
                `SELECT id FROM workout_sessions
                 WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
                [dto.sessionID, userID],
            );
            if (exists.rows.length === 0) {
                throw new HttpError(
                    400,
                    `Referenced session ${dto.sessionID} does not exist`,
                );
            }
        }

        await pool.query(
            `INSERT INTO exercise_entries (
                id, user_id, session_id, name, category, "order", updated_at, deleted_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
             ON CONFLICT (id) DO UPDATE SET
                 session_id = EXCLUDED.session_id,
                 name       = EXCLUDED.name,
                 category   = EXCLUDED.category,
                 "order"    = EXCLUDED."order",
                 updated_at = EXCLUDED.updated_at,
                 deleted_at = EXCLUDED.deleted_at
             WHERE exercise_entries.updated_at <= EXCLUDED.updated_at
               AND exercise_entries.user_id = EXCLUDED.user_id`,
            [
                dto.id,
                userID,
                dto.sessionID ?? null,
                dto.name,
                dto.category,
                dto.order,
                dto.updatedAt,
                dto.deletedAt ?? null,
            ],
        );

        const { rows } = await pool.query<ExerciseEntryRow>(
            `SELECT ${EXERCISE_ENTRY_COLUMNS}
             FROM exercise_entries WHERE id = $1 AND user_id = $2`,
            [dto.id, userID],
        );
        const row = rows[0];
        if (!row) {
            // Either the row was never owned by this caller, or the LWW
            // user_id guard rejected the upsert because someone else
            // already owns this UUID. 404 either way -- we don't leak
            // that the row exists elsewhere.
            throw new HttpError(404, `Exercise entry ${urlID} not found`);
        }
        res.json(mapExerciseEntryRow(row, []));
    }),
);

/** DELETE /exercise-entries/:id -- soft delete; cascades to sets. */
router.delete(
    "/exercise-entries/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
        await pool.query(
            `UPDATE workout_sets SET deleted_at = $2, updated_at = $2
             WHERE exercise_id = $1 AND user_id = $3 AND deleted_at IS NULL`,
            [id, now, userID],
        );
        const result = await pool.query(
            `UPDATE exercise_entries SET deleted_at = $2, updated_at = $2
             WHERE id = $1 AND user_id = $3 AND deleted_at IS NULL`,
            [id, now, userID],
        );
        if (result.rowCount === 0) {
            throw new HttpError(404, `Exercise entry ${id} not found`);
        }
        res.status(204).send();
    }),
);

export default router;
