// Workout template CRUD.
//
// Templates are saved workouts (name + exercise list) the user reuses as
// blueprints for new sessions. They mirror the session/exercise/set
// tables but two levels deep instead of three. Sync semantics are
// identical -- last-write-wins on updated_at, soft-delete via
// deleted_at, user_id scoping on every query.
//
// The PUT endpoint uses a deep upsert (template + nested exercises in a
// single transaction) so the iOS client can save a completed workout as
// a template with one HTTP call.

import { Router } from "express";
import type { PoolClient } from "pg";
import { pool, withTransaction } from "../db.js";
import {
    WORKOUT_TEMPLATE_COLUMNS,
    hydrateTemplate,
    type WorkoutTemplateRow,
} from "../mappers.js";
import {
    asyncHandler,
    HttpError,
    requireUserID,
    requireUUID,
} from "../middleware.js";
import {
    TemplateExerciseSchema,
    WorkoutTemplateSchema,
    parse,
    type TemplateExerciseDTO,
    type WorkoutTemplateDTO,
} from "../schemas.js";

const router = Router();

/**
 * Upsert a template and its child exercises atomically. Shared with the
 * sync path: iOS calls PUT /workout-templates/:id when saving a new
 * template and the server walks into this function to persist the tree.
 *
 * Every UPDATE predicate includes `user_id = EXCLUDED.user_id` so a
 * client that guesses another user's template UUID can't overwrite it
 * via LWW alone.
 */
export async function upsertTemplateDeep(
    client: PoolClient,
    userID: string,
    template: WorkoutTemplateDTO,
): Promise<void> {
    await client.query(
        `INSERT INTO workout_templates (
            id, user_id, name, "order", updated_at, deleted_at
         ) VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (id) DO UPDATE SET
             name       = EXCLUDED.name,
             "order"    = EXCLUDED."order",
             updated_at = EXCLUDED.updated_at,
             deleted_at = EXCLUDED.deleted_at
         WHERE workout_templates.updated_at <= EXCLUDED.updated_at
           AND workout_templates.user_id = EXCLUDED.user_id`,
        [
            template.id,
            userID,
            template.name,
            template.order,
            template.updatedAt,
            template.deletedAt ?? null,
        ],
    );

    for (const exercise of template.exercises) {
        await upsertTemplateExerciseShallow(client, userID, exercise, template.id);
    }
}

async function upsertTemplateExerciseShallow(
    client: Pick<PoolClient, "query">,
    userID: string,
    exercise: TemplateExerciseDTO,
    templateID: string,
): Promise<void> {
    await client.query(
        `INSERT INTO template_exercises (
            id, user_id, template_id, name, category, "order", updated_at, deleted_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         ON CONFLICT (id) DO UPDATE SET
             template_id = EXCLUDED.template_id,
             name        = EXCLUDED.name,
             category    = EXCLUDED.category,
             "order"     = EXCLUDED."order",
             updated_at  = EXCLUDED.updated_at,
             deleted_at  = EXCLUDED.deleted_at
         WHERE template_exercises.updated_at <= EXCLUDED.updated_at
           AND template_exercises.user_id = EXCLUDED.user_id`,
        [
            exercise.id,
            userID,
            exercise.templateID ?? templateID,
            exercise.name,
            exercise.category,
            exercise.order,
            exercise.updatedAt,
            exercise.deletedAt ?? null,
        ],
    );
}

/** GET /workout-templates -- caller's live templates, hydrated. */
router.get(
    "/workout-templates",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const { rows } = await pool.query<WorkoutTemplateRow>(
            `SELECT ${WORKOUT_TEMPLATE_COLUMNS}
             FROM workout_templates
             WHERE user_id = $1 AND deleted_at IS NULL
             ORDER BY "order" ASC, name ASC`,
            [userID],
        );
        const hydrated = await Promise.all(
            rows.map((r) => hydrateTemplate(pool, userID, r)),
        );
        res.json(hydrated);
    }),
);

/** GET /workout-templates/:id -- single live template with nested exercises. */
router.get(
    "/workout-templates/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const { rows } = await pool.query<WorkoutTemplateRow>(
            `SELECT ${WORKOUT_TEMPLATE_COLUMNS}
             FROM workout_templates
             WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
            [id, userID],
        );
        const row = rows[0];
        if (!row) throw new HttpError(404, `Workout template ${id} not found`);
        res.json(await hydrateTemplate(pool, userID, row));
    }),
);

/** PUT /workout-templates/:id -- deep upsert with LWW. */
router.put(
    "/workout-templates/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const urlID = requireUUID(req.params.id);
        const dto = parse(WorkoutTemplateSchema, req.body);
        if (dto.id !== urlID) {
            throw new HttpError(400, "URL id does not match body id");
        }

        const hydrated = await withTransaction(async (client) => {
            await upsertTemplateDeep(client, userID, dto);
            const { rows } = await client.query<WorkoutTemplateRow>(
                `SELECT ${WORKOUT_TEMPLATE_COLUMNS}
                 FROM workout_templates WHERE id = $1 AND user_id = $2`,
                [dto.id, userID],
            );
            const row = rows[0];
            if (!row) {
                throw new HttpError(404, `Workout template ${urlID} not found`);
            }
            return hydrateTemplate(client, userID, row);
        });
        res.json(hydrated);
    }),
);

/** DELETE /workout-templates/:id -- soft delete; cascades to exercises. */
router.delete(
    "/workout-templates/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        await withTransaction(async (client) => {
            const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
            await client.query(
                `UPDATE template_exercises
                 SET deleted_at = $2, updated_at = $2
                 WHERE template_id = $1 AND user_id = $3 AND deleted_at IS NULL`,
                [id, now, userID],
            );
            const result = await client.query(
                `UPDATE workout_templates SET deleted_at = $2, updated_at = $2
                 WHERE id = $1 AND user_id = $3 AND deleted_at IS NULL`,
                [id, now, userID],
            );
            if (result.rowCount === 0) {
                throw new HttpError(404, `Workout template ${id} not found`);
            }
        });
        res.status(204).send();
    }),
);

/**
 * PUT /template-exercises/:id -- shallow upsert for a single exercise.
 * The iOS sync engine uses this when it pushes a dirty TemplateExercise
 * whose parent template already exists on the server.
 */
router.put(
    "/template-exercises/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const urlID = requireUUID(req.params.id);
        const dto = parse(TemplateExerciseSchema, req.body);
        if (dto.id !== urlID) {
            throw new HttpError(400, "URL id does not match body id");
        }

        // FK + ownership guard: template must exist, be live, and belong
        // to the caller.
        if (dto.templateID) {
            const exists = await pool.query<{ id: string }>(
                `SELECT id FROM workout_templates
                 WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
                [dto.templateID, userID],
            );
            if (exists.rows.length === 0) {
                throw new HttpError(
                    400,
                    `Referenced template ${dto.templateID} does not exist`,
                );
            }
        }

        await upsertTemplateExerciseShallow(pool, userID, dto, dto.templateID ?? "");
        res.json(dto);
    }),
);

/** DELETE /template-exercises/:id -- soft delete single exercise. */
router.delete(
    "/template-exercises/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
        const result = await pool.query(
            `UPDATE template_exercises SET deleted_at = $2, updated_at = $2
             WHERE id = $1 AND user_id = $3 AND deleted_at IS NULL`,
            [id, now, userID],
        );
        if (result.rowCount === 0) {
            throw new HttpError(404, `Template exercise ${id} not found`);
        }
        res.status(204).send();
    }),
);

export default router;
