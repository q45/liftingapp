import { z } from "zod";

/**
 * Zod schemas that mirror the Swift DTOs in lifting/DataLayer.swift.
 *
 * Wire-format notes:
 * - Swift's `JSONEncoder` with `.iso8601` produces "2026-04-20T13:57:00Z".
 *   `z.string().datetime({ offset: true })` accepts that plus variants with
 *   fractional seconds and non-UTC offsets, so the server is lenient on
 *   input and strict on output.
 * - Optional Swift properties are *omitted* from JSON (not emitted as null).
 *   Our schemas declare them as `.nullable().optional()` so both missing
 *   keys and explicit nulls validate.
 */

const isoDate = z.string().datetime({ offset: true });
const optionalIsoDate = isoDate.nullable().optional();

/**
 * Sync columns present on every DTO:
 *   updatedAt  -- monotonic last-write-wins timestamp. Client sets it on
 *                 every local edit; server trusts and stores it as-is.
 *                 Required on the wire so there's no ambiguity.
 *   deletedAt  -- soft-delete tombstone. `null` means live.
 */
const syncFields = {
    updatedAt: isoDate,
    deletedAt: optionalIsoDate,
};

// MARK: - Core sync DTOs

export const WorkoutSetSchema = z.object({
    id: z.string().uuid(),
    exerciseID: z.string().uuid().nullable().optional(),
    weight: z.number().finite(),
    reps: z.number().int().min(0),
    order: z.number().int().min(0),
    ...syncFields,
});
export type WorkoutSetDTO = z.infer<typeof WorkoutSetSchema>;

export const ExerciseEntrySchema = z.object({
    id: z.string().uuid(),
    sessionID: z.string().uuid().nullable().optional(),
    name: z.string().min(1),
    category: z.string().min(1),
    order: z.number().int().min(0),
    sets: z.array(WorkoutSetSchema),
    ...syncFields,
});
export type ExerciseEntryDTO = z.infer<typeof ExerciseEntrySchema>;

export const WorkoutSessionSchema = z.object({
    id: z.string().uuid(),
    startTime: isoDate,
    endTime: isoDate,
    isCompleted: z.boolean(),
    // Weak reference to the WorkoutTemplate the user started this session
    // from. Nullable because ad-hoc sessions aren't derived from a
    // template. Unenforced at the DB level (no FK) so sync races between
    // template push and session push don't cascade into session upsert
    // failures -- we treat this as an analytics tag, not a hard relation.
    startedFromTemplateID: z.string().uuid().nullable().optional(),
    exercises: z.array(ExerciseEntrySchema),
    ...syncFields,
});
export type WorkoutSessionDTO = z.infer<typeof WorkoutSessionSchema>;

// MARK: - Template DTOs
//
// Templates mirror the session/exercise/set trio but shallower: a
// template is just a named list of exercises with no sets. Sync columns
// are identical so the same SyncEngine push/pull machinery applies.

export const TemplateExerciseSchema = z.object({
    id: z.string().uuid(),
    templateID: z.string().uuid().nullable().optional(),
    name: z.string().min(1).max(80),
    category: z.string().min(1).max(40),
    order: z.number().int().min(0),
    ...syncFields,
});
export type TemplateExerciseDTO = z.infer<typeof TemplateExerciseSchema>;

export const WorkoutTemplateSchema = z.object({
    id: z.string().uuid(),
    name: z.string().min(1).max(60),
    order: z.number().int().min(0),
    exercises: z.array(TemplateExerciseSchema),
    ...syncFields,
});
export type WorkoutTemplateDTO = z.infer<typeof WorkoutTemplateSchema>;

// MARK: - User profile
//
// Singleton per user: every user has at most one profile row, keyed by
// user_id. The AI coach reads this on every prompt build to personalize
// recommendations (age/experience/goal/equipment bias the programming
// advice). Every field is nullable so users can fill it in incrementally
// -- an empty profile is valid and the coach simply has less to work
// with. Sync columns present so the existing SyncEngine handles writes
// the same as every other record.
//
// Enum fields are validated by `z.enum` so a drifted client (older
// installed version after we add a new category) still validates; we
// coerce unknown values to null on read rather than rejecting. See
// server/src/routes/profile.ts.

export const Sex = z.enum(["male", "female", "other", "prefer_not_to_say"]);
export const ExperienceLevel = z.enum(["novice", "intermediate", "advanced"]);
export const PrimaryGoal = z.enum([
    "strength",
    "hypertrophy",
    "fat_loss",
    "general",
    "powerlifting",
]);
export const EquipmentAccess = z.enum([
    "full_gym",
    "home_gym",
    "bodyweight",
    "limited",
]);
export const Unit = z.enum(["lbs", "kg"]);

export const UserProfileSchema = z.object({
    birthYear: z.number().int().min(1900).max(2100).nullable().optional(),
    sex: Sex.nullable().optional(),
    heightCm: z.number().finite().min(50).max(300).nullable().optional(),
    experienceLevel: ExperienceLevel.nullable().optional(),
    trainingDaysPerWeek: z.number().int().min(1).max(7).nullable().optional(),
    primaryGoal: PrimaryGoal.nullable().optional(),
    equipmentAccess: EquipmentAccess.nullable().optional(),
    preferredUnit: Unit.nullable().optional(),
    notes: z.string().max(500).nullable().optional(),
    ...syncFields,
});
export type UserProfileDTO = z.infer<typeof UserProfileSchema>;

// MARK: - Body weight log
//
// Time-series of weigh-ins. Always stored in kg server-side; client
// converts for display. `measuredAt` is user-provided and can be
// backdated (user logs yesterday's weight today), so it is distinct from
// `updatedAt` which tracks sync modification time.

export const BodyWeightEntrySchema = z.object({
    id: z.string().uuid(),
    weightKg: z.number().finite().min(20).max(500),
    measuredAt: isoDate,
    notes: z.string().max(200).nullable().optional(),
    ...syncFields,
});
export type BodyWeightEntryDTO = z.infer<typeof BodyWeightEntrySchema>;

/**
 * Response from GET /sync/changes?since=ISO. Bundles every record type that
 * has changed since the cursor in a single round-trip. `serverTime` is the
 * cursor the client should send on the next sync call.
 *
 * Nested arrays inside WorkoutSession / ExerciseEntry DTOs are deliberately
 * empty here. Children are delivered as flat top-level arrays; the client
 * reconciles parent/child via `sessionID` / `exerciseID`.
 */
export const SyncChangesSchema = z.object({
    serverTime: isoDate,
    workoutSessions: z.array(WorkoutSessionSchema),
    exerciseEntries: z.array(ExerciseEntrySchema),
    workoutSets: z.array(WorkoutSetSchema),
    workoutTemplates: z.array(WorkoutTemplateSchema),
    templateExercises: z.array(TemplateExerciseSchema),
    // Profile is delivered as either the single row (changed since cursor)
    // or null (no change). It's not an array because it's 1:1 with the
    // user -- the client replaces its local copy atomically.
    userProfile: UserProfileSchema.nullable(),
    bodyWeightEntries: z.array(BodyWeightEntrySchema),
});
export type SyncChangesDTO = z.infer<typeof SyncChangesSchema>;

// MARK: - AI coach schemas
//
// Response from the LLM is validated against CoachResultSchema on the way
// back in so a malformed/hallucinated payload is caught at the server
// boundary instead of breaking the iOS client. The wrapper CoachResponseSchema
// adds bookkeeping so the client can render a "Cached" badge etc.

export const CoachRecommendationSchema = z.object({
    exerciseName: z.string().min(1).max(60),
    weight: z.number().finite().min(0),
    sets: z.number().int().min(1).max(20),
    reps: z.number().int().min(1).max(50),
    tip: z.string().min(1).max(140),
});
export type CoachRecommendation = z.infer<typeof CoachRecommendationSchema>;

export const CoachResultSchema = z.object({
    summary: z.string().min(1).max(400),
    recommendations: z.array(CoachRecommendationSchema).max(12),
});
export type CoachResult = z.infer<typeof CoachResultSchema>;

export const CoachRequestSchema = z.object({
    goal: z.string().min(1).max(40),
    unit: z.enum(["lbs", "kg"]),
    refresh: z.boolean().optional(),
});
export type CoachRequestDTO = z.infer<typeof CoachRequestSchema>;

export const CoachResponseSchema = z.object({
    createdAt: isoDate,
    expiresAt: isoDate,
    cached: z.boolean(),
    model: z.string().min(1),
    goal: z.string(),
    unit: z.enum(["lbs", "kg"]),
    result: CoachResultSchema,
});
export type CoachResponseDTO = z.infer<typeof CoachResponseSchema>;

// MARK: - Per-exercise coach schemas
//
// Same storage/cache path as the whole-workout coach endpoint, but scoped
// to a single exercise the user is about to train. The response shape is
// narrower: one recommendation plus a short "why" rationale so the UI can
// justify the prescription ("last session you hit X, progressing +5").

export const CoachExerciseResultSchema = z.object({
    rationale: z.string().min(1).max(280),
    recommendation: CoachRecommendationSchema,
});
export type CoachExerciseResult = z.infer<typeof CoachExerciseResultSchema>;

export const CoachExerciseRequestSchema = z.object({
    exerciseName: z.string().min(1).max(60),
    goal: z.string().min(1).max(40),
    unit: z.enum(["lbs", "kg"]),
    refresh: z.boolean().optional(),
});
export type CoachExerciseRequestDTO = z.infer<typeof CoachExerciseRequestSchema>;

export const CoachExerciseResponseSchema = z.object({
    createdAt: isoDate,
    expiresAt: isoDate,
    cached: z.boolean(),
    model: z.string().min(1),
    goal: z.string(),
    unit: z.enum(["lbs", "kg"]),
    exerciseName: z.string(),
    result: CoachExerciseResultSchema,
});
export type CoachExerciseResponseDTO = z.infer<typeof CoachExerciseResponseSchema>;

/**
 * Parse a request body with a Zod schema, throwing a ValidationError on
 * failure. The Express error handler turns that into a 400 JSON response.
 */
export function parse<T>(schema: z.ZodType<T>, data: unknown): T {
    const result = schema.safeParse(data);
    if (!result.success) {
        throw new ValidationError(result.error.issues);
    }
    return result.data;
}

export class ValidationError extends Error {
    issues: z.ZodIssue[];
    constructor(issues: z.ZodIssue[]) {
        super("Validation failed");
        this.issues = issues;
        this.name = "ValidationError";
    }
}
