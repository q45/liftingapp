import { Router } from "express";
import { pool } from "../db.js";
import {
    WORKOUT_SET_COLUMNS,
    mapWorkoutSetRow,
    type WorkoutSetRow,
} from "../mappers.js";
import {
    asyncHandler,
    HttpError,
    requireUserID,
    requireUUID,
} from "../middleware.js";
import { WorkoutSetSchema, parse } from "../schemas.js";

const router = Router();

/** GET /workout-sets/:id -- returns live rows only. */
router.get(
    "/workout-sets/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const { rows } = await pool.query<WorkoutSetRow>(
            `SELECT ${WORKOUT_SET_COLUMNS}
             FROM workout_sets
             WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
            [id, userID],
        );
        const row = rows[0];
        if (!row) throw new HttpError(404, `Workout set ${id} not found`);
        res.json(mapWorkoutSetRow(row));
    }),
);

/** PUT /workout-sets/:id -- upsert with last-write-wins. */
router.put(
    "/workout-sets/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const urlID = requireUUID(req.params.id);
        const dto = parse(WorkoutSetSchema, req.body);
        if (dto.id !== urlID) {
            throw new HttpError(400, "URL id does not match body id");
        }

        if (dto.exerciseID) {
            // FK + ownership guard: referenced exercise must be the
            // caller's own, not just any live exercise in the DB.
            const exists = await pool.query<{ id: string }>(
                `SELECT id FROM exercise_entries
                 WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
                [dto.exerciseID, userID],
            );
            if (exists.rows.length === 0) {
                throw new HttpError(
                    400,
                    `Referenced exercise ${dto.exerciseID} does not exist`,
                );
            }
        }

        await pool.query(
            `INSERT INTO workout_sets (
                id, user_id, exercise_id, weight, reps, "order", updated_at, deleted_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
             ON CONFLICT (id) DO UPDATE SET
                 exercise_id = EXCLUDED.exercise_id,
                 weight      = EXCLUDED.weight,
                 reps        = EXCLUDED.reps,
                 "order"     = EXCLUDED."order",
                 updated_at  = EXCLUDED.updated_at,
                 deleted_at  = EXCLUDED.deleted_at
             WHERE workout_sets.updated_at <= EXCLUDED.updated_at
               AND workout_sets.user_id = EXCLUDED.user_id`,
            [
                dto.id,
                userID,
                dto.exerciseID ?? null,
                dto.weight,
                dto.reps,
                dto.order,
                dto.updatedAt,
                dto.deletedAt ?? null,
            ],
        );

        const { rows } = await pool.query<WorkoutSetRow>(
            `SELECT ${WORKOUT_SET_COLUMNS} FROM workout_sets
             WHERE id = $1 AND user_id = $2`,
            [dto.id, userID],
        );
        const row = rows[0];
        if (!row) {
            throw new HttpError(404, `Workout set ${urlID} not found`);
        }
        res.json(mapWorkoutSetRow(row));
    }),
);

/** DELETE /workout-sets/:id -- soft delete. */
router.delete(
    "/workout-sets/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
        const result = await pool.query(
            `UPDATE workout_sets
             SET deleted_at = $2, updated_at = $2
             WHERE id = $1 AND user_id = $3 AND deleted_at IS NULL`,
            [id, now, userID],
        );
        if (result.rowCount === 0) {
            throw new HttpError(404, `Workout set ${id} not found`);
        }
        res.status(204).send();
    }),
);

export default router;
