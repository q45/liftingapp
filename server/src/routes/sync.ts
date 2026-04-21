import { Router } from "express";
import { pool } from "../db.js";
import {
    BODY_WEIGHT_LOG_COLUMNS,
    EXERCISE_ENTRY_COLUMNS,
    TEMPLATE_EXERCISE_COLUMNS,
    USER_PROFILE_COLUMNS,
    WORKOUT_SESSION_COLUMNS,
    WORKOUT_SET_COLUMNS,
    WORKOUT_TEMPLATE_COLUMNS,
    mapBodyWeightLogRow,
    mapExerciseEntryRow,
    mapTemplateExerciseRow,
    mapUserProfileRow,
    mapWorkoutSessionRow,
    mapWorkoutSetRow,
    mapWorkoutTemplateRow,
    type BodyWeightLogRow,
    type ExerciseEntryRow,
    type TemplateExerciseRow,
    type UserProfileRow,
    type WorkoutSessionRow,
    type WorkoutSetRow,
    type WorkoutTemplateRow,
} from "../mappers.js";
import { asyncHandler, HttpError, requireUserID } from "../middleware.js";
import type { SyncChangesDTO } from "../schemas.js";

const router = Router();

/**
 * Clients save the last successful sync time (from serverTime in the
 * previous response) and pass it back here. We return every record whose
 * updated_at is STRICTLY GREATER THAN that cursor -- including tombstones
 * so clients can mirror deletions locally.
 *
 * The response also echoes back the server's "now" as the cursor for the
 * next call. We take `now` BEFORE running queries so writes that sneak in
 * during the response aren't missed, at the cost of occasionally
 * re-sending the same record.
 *
 * Nested arrays inside sessions / exercises are deliberately empty here.
 * Children are delivered as flat top-level arrays and the client wires
 * parents to children via sessionID / exerciseID.
 */
router.get(
    "/sync/changes",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const since = typeof req.query.since === "string" ? req.query.since : undefined;
        if (since) {
            const d = new Date(since);
            if (Number.isNaN(d.getTime())) {
                throw new HttpError(400, "`since` must be an ISO-8601 timestamp");
            }
        }

        const cursor = since ?? "1970-01-01T00:00:00Z";
        const serverTime = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

        // Pull only the caller's own rows. The idx_*_user_updated
        // composite indexes cover this exact (user_id, updated_at > ?)
        // query so pagination stays constant-time regardless of how big
        // other users' datasets grow.
        const [
            sessionsResult,
            exercisesResult,
            setsResult,
            templatesResult,
            templateExercisesResult,
            profileResult,
            bodyWeightResult,
        ] = await Promise.all([
            pool.query<WorkoutSessionRow>(
                `SELECT ${WORKOUT_SESSION_COLUMNS}
                 FROM workout_sessions
                 WHERE user_id = $1 AND updated_at > $2
                 ORDER BY updated_at ASC`,
                [userID, cursor],
            ),
            pool.query<ExerciseEntryRow>(
                `SELECT ${EXERCISE_ENTRY_COLUMNS}
                 FROM exercise_entries
                 WHERE user_id = $1 AND updated_at > $2
                 ORDER BY updated_at ASC`,
                [userID, cursor],
            ),
            pool.query<WorkoutSetRow>(
                `SELECT ${WORKOUT_SET_COLUMNS}
                 FROM workout_sets
                 WHERE user_id = $1 AND updated_at > $2
                 ORDER BY updated_at ASC`,
                [userID, cursor],
            ),
            pool.query<WorkoutTemplateRow>(
                `SELECT ${WORKOUT_TEMPLATE_COLUMNS}
                 FROM workout_templates
                 WHERE user_id = $1 AND updated_at > $2
                 ORDER BY updated_at ASC`,
                [userID, cursor],
            ),
            pool.query<TemplateExerciseRow>(
                `SELECT ${TEMPLATE_EXERCISE_COLUMNS}
                 FROM template_exercises
                 WHERE user_id = $1 AND updated_at > $2
                 ORDER BY updated_at ASC`,
                [userID, cursor],
            ),
            // Profile is 1:1 with user, so at most one row ever comes
            // back. Return null if unchanged since the cursor; the client
            // treats null as "no delta for profile this cycle".
            pool.query<UserProfileRow>(
                `SELECT ${USER_PROFILE_COLUMNS}
                 FROM user_profiles
                 WHERE user_id = $1 AND updated_at > $2`,
                [userID, cursor],
            ),
            pool.query<BodyWeightLogRow>(
                `SELECT ${BODY_WEIGHT_LOG_COLUMNS}
                 FROM body_weight_logs
                 WHERE user_id = $1 AND updated_at > $2
                 ORDER BY updated_at ASC`,
                [userID, cursor],
            ),
        ]);

        const profileRow = profileResult.rows[0];

        const payload: SyncChangesDTO = {
            serverTime,
            workoutSessions: sessionsResult.rows.map((r) => mapWorkoutSessionRow(r, [])),
            exerciseEntries: exercisesResult.rows.map((r) => mapExerciseEntryRow(r, [])),
            workoutSets: setsResult.rows.map(mapWorkoutSetRow),
            workoutTemplates: templatesResult.rows.map((r) => mapWorkoutTemplateRow(r, [])),
            templateExercises: templateExercisesResult.rows.map(mapTemplateExerciseRow),
            userProfile: profileRow ? mapUserProfileRow(profileRow) : null,
            bodyWeightEntries: bodyWeightResult.rows.map(mapBodyWeightLogRow),
        };

        res.json(payload);
    }),
);

export default router;
