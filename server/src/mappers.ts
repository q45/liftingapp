import type { PoolClient } from "pg";
import type {
    BodyWeightEntryDTO,
    ExerciseEntryDTO,
    TemplateExerciseDTO,
    UserProfileDTO,
    WorkoutSessionDTO,
    WorkoutSetDTO,
    WorkoutTemplateDTO,
} from "./schemas.js";

/**
 * Row types reflect the columns selected from each table (snake_case from
 * PG, not the camelCase DTOs). Timestamp columns arrive as pre-formatted
 * ISO-8601 strings without milliseconds thanks to the custom type parsers
 * in db.ts.
 */

interface SyncColumns {
    updated_at: string;
    deleted_at: string | null;
}

interface WorkoutSessionRow extends SyncColumns {
    id: string;
    start_time: string;
    end_time: string;
    is_completed: boolean;
    started_from_template_id: string | null;
}

interface ExerciseEntryRow extends SyncColumns {
    id: string;
    session_id: string | null;
    name: string;
    category: string;
    order: number;
}

interface WorkoutSetRow extends SyncColumns {
    id: string;
    exercise_id: string | null;
    weight: number | string;
    reps: number;
    duration_seconds: number | null;
    order: number;
}

interface WorkoutTemplateRow extends SyncColumns {
    id: string;
    name: string;
    order: number;
}

interface TemplateExerciseRow extends SyncColumns {
    id: string;
    template_id: string | null;
    name: string;
    category: string;
    order: number;
}

interface UserProfileRow extends SyncColumns {
    birth_year: number | null;
    sex: string | null;
    height_cm: number | string | null;
    experience_level: string | null;
    training_days_per_week: number | null;
    primary_goal: string | null;
    equipment_access: string | null;
    preferred_unit: string | null;
    notes: string | null;
}

interface BodyWeightLogRow extends SyncColumns {
    id: string;
    weight_kg: number | string;
    measured_at: string;
    notes: string | null;
}

// Standard column selection lists. Centralised so every query returns the
// same shape and mappers stay in sync with them.
export const WORKOUT_SESSION_COLUMNS =
    "id, start_time, end_time, is_completed, started_from_template_id, updated_at, deleted_at";
export const EXERCISE_ENTRY_COLUMNS =
    `id, session_id, name, category, "order", updated_at, deleted_at`;
export const WORKOUT_SET_COLUMNS =
    `id, exercise_id, weight, reps, duration_seconds, "order", updated_at, deleted_at`;
export const WORKOUT_TEMPLATE_COLUMNS =
    `id, name, "order", updated_at, deleted_at`;
export const TEMPLATE_EXERCISE_COLUMNS =
    `id, template_id, name, category, "order", updated_at, deleted_at`;
export const USER_PROFILE_COLUMNS =
    "birth_year, sex, height_cm, experience_level, training_days_per_week, primary_goal, equipment_access, preferred_unit, notes, updated_at, deleted_at";
export const BODY_WEIGHT_LOG_COLUMNS =
    "id, weight_kg, measured_at, notes, updated_at, deleted_at";

function toNumber(value: number | string | null | undefined): number | null {
    if (value === null || value === undefined) return null;
    const n = typeof value === "number" ? value : Number(value);
    return Number.isFinite(n) ? n : null;
}

export function mapWorkoutSetRow(row: WorkoutSetRow): WorkoutSetDTO {
    return {
        id: row.id,
        exerciseID: row.exercise_id,
        weight: toNumber(row.weight) ?? 0,
        reps: row.reps,
        durationSeconds: row.duration_seconds,
        order: row.order,
        updatedAt: row.updated_at,
        deletedAt: row.deleted_at,
    };
}

export function mapExerciseEntryRow(
    row: ExerciseEntryRow,
    sets: WorkoutSetDTO[] = [],
): ExerciseEntryDTO {
    return {
        id: row.id,
        sessionID: row.session_id,
        name: row.name,
        category: row.category,
        order: row.order,
        sets,
        updatedAt: row.updated_at,
        deletedAt: row.deleted_at,
    };
}

export function mapWorkoutSessionRow(
    row: WorkoutSessionRow,
    exercises: ExerciseEntryDTO[] = [],
): WorkoutSessionDTO {
    return {
        id: row.id,
        startTime: row.start_time,
        endTime: row.end_time,
        isCompleted: row.is_completed,
        startedFromTemplateID: row.started_from_template_id,
        exercises,
        updatedAt: row.updated_at,
        deletedAt: row.deleted_at,
    };
}

// ---------------------------------------------------------------------------
// Hydration helpers: fetch records with nested children in minimum round-trips.
// ---------------------------------------------------------------------------

type Queryable = Pick<PoolClient, "query">;

// All hydration helpers require the caller's userID so the nested-child
// queries are scoped to the authenticated user. Without this a caller
// could hydrate their own top-level session but receive a second user's
// exercise rows purely because the session FK chain matched -- an
// authorization leak if two users ever shared a row id (e.g. via
// restored-from-backup UUIDs).

export async function loadSetsForExercises(
    db: Queryable,
    userID: string,
    exerciseIDs: string[],
): Promise<Map<string, WorkoutSetDTO[]>> {
    const map = new Map<string, WorkoutSetDTO[]>();
    if (exerciseIDs.length === 0) return map;

    const { rows } = await db.query<WorkoutSetRow>(
        `SELECT ${WORKOUT_SET_COLUMNS}
         FROM workout_sets
         WHERE user_id = $1
           AND exercise_id = ANY($2::uuid[])
           AND deleted_at IS NULL
         ORDER BY "order" ASC`,
        [userID, exerciseIDs],
    );

    for (const row of rows) {
        const dto = mapWorkoutSetRow(row);
        const key = dto.exerciseID ?? "";
        if (!key) continue;
        const list = map.get(key) ?? [];
        list.push(dto);
        map.set(key, list);
    }
    return map;
}

export async function loadExercisesForSessions(
    db: Queryable,
    userID: string,
    sessionIDs: string[],
): Promise<Map<string, ExerciseEntryDTO[]>> {
    const map = new Map<string, ExerciseEntryDTO[]>();
    if (sessionIDs.length === 0) return map;

    const { rows } = await db.query<ExerciseEntryRow>(
        `SELECT ${EXERCISE_ENTRY_COLUMNS}
         FROM exercise_entries
         WHERE user_id = $1
           AND session_id = ANY($2::uuid[])
           AND deleted_at IS NULL
         ORDER BY "order" ASC`,
        [userID, sessionIDs],
    );

    const exerciseIDs = rows.map((r) => r.id);
    const setsMap = await loadSetsForExercises(db, userID, exerciseIDs);

    for (const row of rows) {
        const dto = mapExerciseEntryRow(row, setsMap.get(row.id) ?? []);
        const key = dto.sessionID ?? "";
        if (!key) continue;
        const list = map.get(key) ?? [];
        list.push(dto);
        map.set(key, list);
    }
    return map;
}

export async function hydrateSession(
    db: Queryable,
    userID: string,
    row: WorkoutSessionRow,
): Promise<WorkoutSessionDTO> {
    const map = await loadExercisesForSessions(db, userID, [row.id]);
    return mapWorkoutSessionRow(row, map.get(row.id) ?? []);
}

export async function hydrateExercise(
    db: Queryable,
    userID: string,
    row: ExerciseEntryRow,
): Promise<ExerciseEntryDTO> {
    const map = await loadSetsForExercises(db, userID, [row.id]);
    return mapExerciseEntryRow(row, map.get(row.id) ?? []);
}

// ---------------------------------------------------------------------------
// Template row mappers + hydration
// ---------------------------------------------------------------------------

export function mapTemplateExerciseRow(row: TemplateExerciseRow): TemplateExerciseDTO {
    return {
        id: row.id,
        templateID: row.template_id,
        name: row.name,
        category: row.category,
        order: row.order,
        updatedAt: row.updated_at,
        deletedAt: row.deleted_at,
    };
}

export function mapWorkoutTemplateRow(
    row: WorkoutTemplateRow,
    exercises: TemplateExerciseDTO[] = [],
): WorkoutTemplateDTO {
    return {
        id: row.id,
        name: row.name,
        order: row.order,
        exercises,
        updatedAt: row.updated_at,
        deletedAt: row.deleted_at,
    };
}

export async function loadExercisesForTemplates(
    db: Queryable,
    userID: string,
    templateIDs: string[],
): Promise<Map<string, TemplateExerciseDTO[]>> {
    const map = new Map<string, TemplateExerciseDTO[]>();
    if (templateIDs.length === 0) return map;

    const { rows } = await db.query<TemplateExerciseRow>(
        `SELECT ${TEMPLATE_EXERCISE_COLUMNS}
         FROM template_exercises
         WHERE user_id = $1
           AND template_id = ANY($2::uuid[])
           AND deleted_at IS NULL
         ORDER BY "order" ASC`,
        [userID, templateIDs],
    );

    for (const row of rows) {
        const dto = mapTemplateExerciseRow(row);
        const key = dto.templateID ?? "";
        if (!key) continue;
        const list = map.get(key) ?? [];
        list.push(dto);
        map.set(key, list);
    }
    return map;
}

export async function hydrateTemplate(
    db: Queryable,
    userID: string,
    row: WorkoutTemplateRow,
): Promise<WorkoutTemplateDTO> {
    const map = await loadExercisesForTemplates(db, userID, [row.id]);
    return mapWorkoutTemplateRow(row, map.get(row.id) ?? []);
}

// ---------------------------------------------------------------------------
// Profile + body-weight mappers
// ---------------------------------------------------------------------------
//
// Profile enums are stored as plain TEXT server-side (not a CHECK) so an
// older server can accept values from a newer client without deploying a
// migration. The mapper passes values through verbatim; Zod re-validates
// on the way out via UserProfileSchema, coercing unknown enum values to
// null so a forward-incompatible value never pollutes the wire.

export function mapUserProfileRow(row: UserProfileRow): UserProfileDTO {
    return {
        birthYear: row.birth_year,
        sex: row.sex as UserProfileDTO["sex"],
        heightCm: toNumber(row.height_cm),
        experienceLevel: row.experience_level as UserProfileDTO["experienceLevel"],
        trainingDaysPerWeek: row.training_days_per_week,
        primaryGoal: row.primary_goal as UserProfileDTO["primaryGoal"],
        equipmentAccess: row.equipment_access as UserProfileDTO["equipmentAccess"],
        preferredUnit: row.preferred_unit as UserProfileDTO["preferredUnit"],
        notes: row.notes,
        updatedAt: row.updated_at,
        deletedAt: row.deleted_at,
    };
}

export function mapBodyWeightLogRow(row: BodyWeightLogRow): BodyWeightEntryDTO {
    return {
        id: row.id,
        weightKg: toNumber(row.weight_kg) ?? 0,
        measuredAt: row.measured_at,
        notes: row.notes,
        updatedAt: row.updated_at,
        deletedAt: row.deleted_at,
    };
}

export type {
    WorkoutSessionRow,
    ExerciseEntryRow,
    WorkoutSetRow,
    WorkoutTemplateRow,
    TemplateExerciseRow,
    UserProfileRow,
    BodyWeightLogRow,
};
