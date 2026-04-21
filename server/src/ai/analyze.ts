// Orchestrator for the coach recommendations endpoint: pulls recent
// sessions from Postgres, builds a prompt, calls Anthropic, validates the
// JSON response with Zod, and caches the result.
//
// Errors bubble up to the route layer via AnalyzeError, which maps to HTTP.

import Anthropic from "@anthropic-ai/sdk";
import { createHash } from "node:crypto";
import type { PoolClient } from "pg";
import { pool } from "../db.js";
import {
    BODY_WEIGHT_LOG_COLUMNS,
    USER_PROFILE_COLUMNS,
    WORKOUT_SESSION_COLUMNS,
    hydrateSession,
    mapBodyWeightLogRow,
    mapUserProfileRow,
    type BodyWeightLogRow,
    type UserProfileRow,
    type WorkoutSessionRow,
} from "../mappers.js";
import {
    CoachExerciseResultSchema,
    CoachResultSchema,
    type BodyWeightEntryDTO,
    type CoachExerciseResponseDTO,
    type CoachExerciseResult,
    type CoachResponseDTO,
    type CoachResult,
    type UserProfileDTO,
} from "../schemas.js";
import { buildCoachPrompt, buildExerciseCoachPrompt } from "./prompts.js";

const DEFAULT_MODEL = "claude-sonnet-4-5";
const DEFAULT_TTL_SECONDS = 3_600; // 1 hour
const DEFAULT_RECENT_SESSIONS = 6;

// Lazy-instantiate so modules that import this file don't crash on boot
// when ANTHROPIC_API_KEY is unset (e.g. during migrate / typecheck).
let _client: Anthropic | null = null;
function client(): Anthropic {
    if (_client) return _client;
    const apiKey = process.env.ANTHROPIC_API_KEY?.trim();
    if (!apiKey) {
        throw new AnalyzeError(
            503,
            "ANTHROPIC_API_KEY not configured. Set it in server/.env to enable AI coach.",
        );
    }
    _client = new Anthropic({ apiKey });
    return _client;
}

function modelName(): string {
    return process.env.ANTHROPIC_MODEL?.trim() || DEFAULT_MODEL;
}

function ttlSeconds(): number {
    const raw = process.env.COACH_CACHE_TTL_SECONDS?.trim();
    const parsed = raw ? Number(raw) : DEFAULT_TTL_SECONDS;
    return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_TTL_SECONDS;
}

function recentSessionCount(): number {
    const raw = process.env.COACH_RECENT_SESSIONS?.trim();
    const parsed = raw ? Number(raw) : DEFAULT_RECENT_SESSIONS;
    return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_RECENT_SESSIONS;
}

/** Typed error that the route layer turns into HTTP responses. */
export class AnalyzeError extends Error {
    status: number;
    constructor(status: number, message: string) {
        super(message);
        this.status = status;
        this.name = "AnalyzeError";
    }
}

/**
 * Derive a deterministic UUID for the cache subject. `scope` partitions
 * the cache namespace so a per-exercise recommendation for ("Bench Press",
 * stronger, lbs) can't collide with the whole-workout recommendation for
 * (stronger, lbs). The `user_id` is **not** part of the seed -- we
 * already partition the `coach_analyses` table by `user_id` in the WHERE
 * clause of findFreshCached/persist, so mixing it into the hash would
 * just obscure the key without adding isolation.
 */
function subjectID(scope: string, ...parts: string[]): string {
    const seed = [scope, ...parts].join("|");
    const hash = createHash("sha1").update(seed).digest("hex");
    return [
        hash.slice(0, 8),
        hash.slice(8, 12),
        "5" + hash.slice(13, 16),
        "8" + hash.slice(17, 20),
        hash.slice(20, 32),
    ].join("-");
}

interface CachedRow {
    id: string;
    result: unknown;
    model: string;
    goal: string;
    unit: string;
    created_at: string;
    expires_at: string;
}

async function findFreshCached(
    db: Pick<PoolClient, "query">,
    userID: string,
    subjectId: string,
): Promise<CachedRow | null> {
    const { rows } = await db.query<CachedRow>(
        `SELECT id, result, model, goal, unit, created_at, expires_at
         FROM coach_analyses
         WHERE user_id     = $1
           AND subject_id  = $2
           AND expires_at  > NOW()
         ORDER BY created_at DESC
         LIMIT 1`,
        [userID, subjectId],
    );
    return rows[0] ?? null;
}

async function persist(
    userID: string,
    subjectId: string,
    subjectType: string,
    goal: string,
    unit: string,
    result: CoachResult | CoachExerciseResult,
    model: string,
    promptTokens: number | null,
    completionTokens: number | null,
): Promise<CachedRow> {
    const ttl = ttlSeconds();
    const { rows } = await pool.query<CachedRow>(
        `INSERT INTO coach_analyses (
            user_id, subject_type, subject_id, goal, unit, result, model,
            prompt_tokens, completion_tokens, expires_at
         ) VALUES (
            $1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9,
            NOW() + ($10 || ' seconds')::interval
         )
         RETURNING id, result, model, goal, unit, created_at, expires_at`,
        [
            userID,
            subjectType,
            subjectId,
            goal,
            unit,
            JSON.stringify(result),
            model,
            promptTokens,
            completionTokens,
            String(ttl),
        ],
    );
    return rows[0]!;
}

function extractJSON(text: string): unknown {
    const trimmed = text.trim();
    const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
    const candidate = fenced ? fenced[1]!.trim() : trimmed;
    return JSON.parse(candidate);
}

async function callAnthropic(params: {
    system: string;
    user: string;
    model: string;
}): Promise<{
    raw: unknown;
    promptTokens: number | null;
    completionTokens: number | null;
}> {
    const response = await client().messages.create({
        model: params.model,
        max_tokens: 2048,
        system: params.system,
        messages: [{ role: "user", content: params.user }],
    });

    const textBlock = response.content.find((b) => b.type === "text");
    if (!textBlock || textBlock.type !== "text") {
        throw new AnalyzeError(502, "Claude returned no text content");
    }

    const raw = (() => {
        try {
            return extractJSON(textBlock.text);
        } catch (err) {
            throw new AnalyzeError(
                502,
                `Claude returned non-JSON response: ${(err as Error).message}`,
            );
        }
    })();

    return {
        raw,
        promptTokens: response.usage?.input_tokens ?? null,
        completionTokens: response.usage?.output_tokens ?? null,
    };
}

function toResponseDTO(
    row: CachedRow,
    cachedFlag: boolean,
): CoachResponseDTO {
    return {
        createdAt: row.created_at,
        expiresAt: row.expires_at,
        cached: cachedFlag,
        model: row.model,
        goal: row.goal,
        unit: row.unit as "lbs" | "kg",
        result: row.result as CoachResult,
    };
}

async function loadRecentCompletedSessions(userID: string, limit: number) {
    const { rows } = await pool.query<WorkoutSessionRow>(
        `SELECT ${WORKOUT_SESSION_COLUMNS}
         FROM workout_sessions
         WHERE user_id = $1
           AND deleted_at IS NULL
           AND is_completed = TRUE
         ORDER BY end_time DESC
         LIMIT $2`,
        [userID, limit],
    );
    return Promise.all(rows.map((r) => hydrateSession(pool, userID, r)));
}

/**
 * Fetch the profile + most recent weigh-in for a user, to feed into the
 * AI coach prompt. Both are optional: an empty profile and/or missing
 * body-weight log are valid, and the prompt builder handles the
 * fallbacks. One round-trip per table via Promise.all.
 */
async function loadAthleteContext(userID: string): Promise<{
    profile: UserProfileDTO | null;
    latestWeight: BodyWeightEntryDTO | null;
}> {
    const [profileResult, weightResult] = await Promise.all([
        pool.query<UserProfileRow>(
            `SELECT ${USER_PROFILE_COLUMNS}
             FROM user_profiles
             WHERE user_id = $1 AND deleted_at IS NULL`,
            [userID],
        ),
        pool.query<BodyWeightLogRow>(
            `SELECT ${BODY_WEIGHT_LOG_COLUMNS}
             FROM body_weight_logs
             WHERE user_id = $1 AND deleted_at IS NULL
             ORDER BY measured_at DESC
             LIMIT 1`,
            [userID],
        ),
    ]);
    return {
        profile: profileResult.rows[0] ? mapUserProfileRow(profileResult.rows[0]) : null,
        latestWeight: weightResult.rows[0] ? mapBodyWeightLogRow(weightResult.rows[0]) : null,
    };
}

/**
 * Stable, short fingerprint of the athlete context. Mixed into cache
 * subject IDs so a profile/weight change invalidates stale
 * recommendations. We hash only fields that could actually change the
 * recommendation -- not `updatedAt` (which changes on no-op saves) and
 * not `measuredAt` (the weight value is what matters to the coach, not
 * when it was logged).
 *
 * Empty profile + missing weight produces a deterministic sentinel so
 * users who never fill in a profile still benefit from caching.
 */
function athleteContextFingerprint(
    profile: UserProfileDTO | null,
    latestWeight: BodyWeightEntryDTO | null,
): string {
    const material = JSON.stringify({
        p: profile
            ? {
                  b: profile.birthYear ?? null,
                  s: profile.sex ?? null,
                  h: profile.heightCm ?? null,
                  e: profile.experienceLevel ?? null,
                  d: profile.trainingDaysPerWeek ?? null,
                  g: profile.primaryGoal ?? null,
                  q: profile.equipmentAccess ?? null,
                  u: profile.preferredUnit ?? null,
                  n: profile.notes ?? null,
              }
            : null,
        w: latestWeight ? latestWeight.weightKg : null,
    });
    return createHash("sha1").update(material).digest("hex").slice(0, 12);
}

/**
 * Generate or retrieve the cached coach recommendation.
 *
 * Cache keying: (goal, unit). Changing either bypasses the cache. The
 * TTL is relatively short (1h default) because workouts change often and
 * stale recommendations become misleading quickly.
 */
export async function generateCoachRecommendation(params: {
    userID: string;
    goal: string;
    unit: "lbs" | "kg";
    forceRefresh: boolean;
}): Promise<CoachResponseDTO> {
    // Fetch athlete context up-front so the cache key reflects it.
    // Profile / weight changes bust the cache via the fingerprint; no
    // separate invalidation wiring needed.
    const { profile, latestWeight } = await loadAthleteContext(params.userID);
    const fp = athleteContextFingerprint(profile, latestWeight);
    const subjId = subjectID("workout", params.goal, params.unit, fp);

    if (!params.forceRefresh) {
        const cached = await findFreshCached(pool, params.userID, subjId);
        if (cached && cached.goal === params.goal && cached.unit === params.unit) {
            return toResponseDTO(cached, true);
        }
    }

    const recentSessions = await loadRecentCompletedSessions(
        params.userID,
        recentSessionCount(),
    );
    if (recentSessions.length === 0) {
        throw new AnalyzeError(
            400,
            "Log at least one completed workout before requesting coach recommendations.",
        );
    }

    const { system, user } = buildCoachPrompt({
        goal: params.goal,
        unit: params.unit,
        recentSessions,
        profile,
        latestWeight,
    });

    const { raw, promptTokens, completionTokens } = await callAnthropic({
        system,
        user,
        model: modelName(),
    });

    const parsed = CoachResultSchema.safeParse(raw);
    if (!parsed.success) {
        throw new AnalyzeError(
            502,
            `Claude response failed schema validation: ${JSON.stringify(parsed.error.issues)}`,
        );
    }

    const row = await persist(
        params.userID,
        subjId,
        "workout",
        params.goal,
        params.unit,
        parsed.data,
        modelName(),
        promptTokens,
        completionTokens,
    );
    return toResponseDTO(row, false);
}

// MARK: - Per-exercise coach
//
// Same cache table + Anthropic pipeline as generateCoachRecommendation,
// but scoped to one exercise. Cache key includes a normalized exercise
// name so different exercises (and the global workout endpoint) can't
// collide. TTL reuses COACH_CACHE_TTL_SECONDS.

function normalizeExerciseName(name: string): string {
    return name.trim().toLowerCase();
}

function toExerciseResponseDTO(
    row: CachedRow,
    exerciseName: string,
    cachedFlag: boolean,
): CoachExerciseResponseDTO {
    return {
        createdAt: row.created_at,
        expiresAt: row.expires_at,
        cached: cachedFlag,
        model: row.model,
        goal: row.goal,
        unit: row.unit as "lbs" | "kg",
        exerciseName,
        result: row.result as CoachExerciseResult,
    };
}

/**
 * Generate or retrieve a cached per-exercise coach recommendation.
 *
 * Cache keying: (exerciseName-normalized, goal, unit). The exercise name
 * is lowercased + trimmed so "Bench Press" and "bench press" share a
 * cache entry.
 */
export async function generateExerciseCoachRecommendation(params: {
    userID: string;
    exerciseName: string;
    goal: string;
    unit: "lbs" | "kg";
    forceRefresh: boolean;
}): Promise<CoachExerciseResponseDTO> {
    const { profile, latestWeight } = await loadAthleteContext(params.userID);
    const fp = athleteContextFingerprint(profile, latestWeight);
    const normalized = normalizeExerciseName(params.exerciseName);
    const subjId = subjectID("exercise", normalized, params.goal, params.unit, fp);

    if (!params.forceRefresh) {
        const cached = await findFreshCached(pool, params.userID, subjId);
        if (cached && cached.goal === params.goal && cached.unit === params.unit) {
            return toExerciseResponseDTO(cached, params.exerciseName, true);
        }
    }

    const recentSessions = await loadRecentCompletedSessions(
        params.userID,
        recentSessionCount(),
    );

    // We intentionally don't error when there's zero matching history --
    // the prompt handles the cold-start case by returning a conservative
    // starting prescription. Only error if the user has literally never
    // completed a workout.
    if (recentSessions.length === 0) {
        throw new AnalyzeError(
            400,
            "Log at least one completed workout before requesting coach recommendations.",
        );
    }

    const { system, user } = buildExerciseCoachPrompt({
        exerciseName: params.exerciseName,
        goal: params.goal,
        unit: params.unit,
        recentSessions,
        profile,
        latestWeight,
    });

    const { raw, promptTokens, completionTokens } = await callAnthropic({
        system,
        user,
        model: modelName(),
    });

    const parsed = CoachExerciseResultSchema.safeParse(raw);
    if (!parsed.success) {
        throw new AnalyzeError(
            502,
            `Claude response failed schema validation: ${JSON.stringify(parsed.error.issues)}`,
        );
    }

    const row = await persist(
        params.userID,
        subjId,
        "exercise",
        params.goal,
        params.unit,
        parsed.data,
        modelName(),
        promptTokens,
        completionTokens,
    );
    return toExerciseResponseDTO(row, params.exerciseName, false);
}
