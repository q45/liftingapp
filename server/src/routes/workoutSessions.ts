import { Router } from "express";
import type { PoolClient } from "pg";
import { pool, withTransaction } from "../db.js";
import {
    WORKOUT_SESSION_COLUMNS,
    hydrateSession,
    loadExercisesForSessions,
    mapWorkoutSessionRow,
    type WorkoutSessionRow,
} from "../mappers.js";
import {
    asyncHandler,
    HttpError,
    requireUserID,
    requireUUID,
} from "../middleware.js";
import {
    WorkoutSessionSchema,
    parse,
    type ExerciseEntryDTO,
    type WorkoutSessionDTO,
    type WorkoutSetDTO,
} from "../schemas.js";

const router = Router();

/**
 * Upsert a workout session plus nested exercises and sets in a single
 * transaction. Shared with the /sync code paths so both POST /workout-sessions
 * and a future bulk-push endpoint use identical semantics.
 *
 * The WHERE predicate on each UPDATE implements last-write-wins per row:
 * the server keeps its copy whenever its updated_at > the incoming one.
 * AND the row's user_id matches -- so a client with a session token for
 * user A cannot overwrite or resurrect user B's data even if it knows
 * user B's row UUIDs. The LWW predicate alone would allow that attack.
 */
export async function upsertSessionDeep(
    client: PoolClient,
    userID: string,
    session: WorkoutSessionDTO,
): Promise<void> {
    await client.query(
        `INSERT INTO workout_sessions (
            id, user_id, start_time, end_time, is_completed,
            started_from_template_id, updated_at, deleted_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         ON CONFLICT (id) DO UPDATE SET
             start_time                = EXCLUDED.start_time,
             end_time                  = EXCLUDED.end_time,
             is_completed              = EXCLUDED.is_completed,
             started_from_template_id  = EXCLUDED.started_from_template_id,
             updated_at                = EXCLUDED.updated_at,
             deleted_at                = EXCLUDED.deleted_at
         WHERE workout_sessions.updated_at <= EXCLUDED.updated_at
           AND workout_sessions.user_id = EXCLUDED.user_id`,
        [
            session.id,
            userID,
            session.startTime,
            session.endTime,
            session.isCompleted,
            session.startedFromTemplateID ?? null,
            session.updatedAt,
            session.deletedAt ?? null,
        ],
    );

    for (const entry of session.exercises) {
        await upsertExerciseShallow(client, userID, entry, session.id);
        for (const set of entry.sets) {
            await upsertSetShallow(client, userID, set, entry.id);
        }
    }
}

async function upsertExerciseShallow(
    client: PoolClient,
    userID: string,
    entry: ExerciseEntryDTO,
    sessionID: string,
): Promise<void> {
    await client.query(
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
            entry.id,
            userID,
            entry.sessionID ?? sessionID,
            entry.name,
            entry.category,
            entry.order,
            entry.updatedAt,
            entry.deletedAt ?? null,
        ],
    );
}

async function upsertSetShallow(
    client: PoolClient,
    userID: string,
    set: WorkoutSetDTO,
    exerciseID: string,
): Promise<void> {
    await client.query(
        `INSERT INTO workout_sets (
            id, user_id, exercise_id, weight, reps, duration_seconds,
            "order", updated_at, deleted_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
         ON CONFLICT (id) DO UPDATE SET
             exercise_id      = EXCLUDED.exercise_id,
             weight           = EXCLUDED.weight,
             reps             = EXCLUDED.reps,
             duration_seconds = EXCLUDED.duration_seconds,
             "order"          = EXCLUDED."order",
             updated_at       = EXCLUDED.updated_at,
             deleted_at       = EXCLUDED.deleted_at
         WHERE workout_sets.updated_at <= EXCLUDED.updated_at
           AND workout_sets.user_id = EXCLUDED.user_id`,
        [
            set.id,
            userID,
            set.exerciseID ?? exerciseID,
            set.weight,
            set.reps,
            set.durationSeconds ?? null,
            set.order,
            set.updatedAt,
            set.deletedAt ?? null,
        ],
    );
}

/** GET /workout-sessions -- caller's live sessions only, hydrated. */
router.get(
    "/workout-sessions",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const { rows } = await pool.query<WorkoutSessionRow>(
            `SELECT ${WORKOUT_SESSION_COLUMNS}
             FROM workout_sessions
             WHERE user_id = $1 AND deleted_at IS NULL
             ORDER BY end_time DESC`,
            [userID],
        );
        const ids = rows.map((r) => r.id);
        const map = await loadExercisesForSessions(pool, userID, ids);
        res.json(rows.map((row) => mapWorkoutSessionRow(row, map.get(row.id) ?? [])));
    }),
);

/** GET /workout-sessions/:id -- single live session with nested children. */
router.get(
    "/workout-sessions/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const { rows } = await pool.query<WorkoutSessionRow>(
            `SELECT ${WORKOUT_SESSION_COLUMNS}
             FROM workout_sessions
             WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
            [id, userID],
        );
        const row = rows[0];
        if (!row) throw new HttpError(404, `Workout session ${id} not found`);
        res.json(await hydrateSession(pool, userID, row));
    }),
);

/** PUT /workout-sessions/:id -- upsert with nested exercises/sets. LWW. */
router.put(
    "/workout-sessions/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const urlID = requireUUID(req.params.id);
        const dto = parse(WorkoutSessionSchema, req.body);
        if (dto.id !== urlID) {
            throw new HttpError(400, "URL id does not match body id");
        }

        const hydrated = await withTransaction(async (client) => {
            await upsertSessionDeep(client, userID, dto);
            const { rows } = await client.query<WorkoutSessionRow>(
                `SELECT ${WORKOUT_SESSION_COLUMNS}
                 FROM workout_sessions WHERE id = $1 AND user_id = $2`,
                [dto.id, userID],
            );
            const row = rows[0];
            if (!row) {
                // Either the row was never created (because the upsert's
                // user_id guard rejected it -- someone tried to hijack
                // another user's row UUID), or LWW left a foreign row in
                // place. Either way the authenticated user has no right
                // to see it, so we 404 rather than leak existence.
                throw new HttpError(404, `Workout session ${urlID} not found`);
            }
            return hydrateSession(client, userID, row);
        });
        res.json(hydrated);
    }),
);

/** DELETE /workout-sessions/:id -- soft delete; cascades to exercises/sets. */
router.delete(
    "/workout-sessions/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        await withTransaction(async (client) => {
            const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
            await client.query(
                `UPDATE workout_sets
                 SET deleted_at = $2, updated_at = $2
                 WHERE exercise_id IN (
                    SELECT id FROM exercise_entries
                    WHERE session_id = $1 AND user_id = $3
                 ) AND user_id = $3 AND deleted_at IS NULL`,
                [id, now, userID],
            );
            await client.query(
                `UPDATE exercise_entries
                 SET deleted_at = $2, updated_at = $2
                 WHERE session_id = $1 AND user_id = $3 AND deleted_at IS NULL`,
                [id, now, userID],
            );
            const result = await client.query(
                `UPDATE workout_sessions SET deleted_at = $2, updated_at = $2
                 WHERE id = $1 AND user_id = $3 AND deleted_at IS NULL`,
                [id, now, userID],
            );
            if (result.rowCount === 0) {
                throw new HttpError(404, `Workout session ${id} not found`);
            }
        });
        res.status(204).send();
    }),
);

export default router;
