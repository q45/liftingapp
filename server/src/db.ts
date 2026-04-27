import "dotenv/config";
import pg from "pg";

const { Pool, types } = pg;

// Return TIMESTAMPTZ (OID 1184) and TIMESTAMP (OID 1114) as ISO-8601 strings
// with no fractional seconds. Swift's JSONDecoder `.iso8601` strategy uses
// ISO8601DateFormatter with `[.withInternetDateTime]`, which rejects
// fractional seconds like "2026-04-20T13:57:00.000Z". Formatting here avoids
// per-mapper conversion and guarantees the wire format Swift expects.
const stripMillis = (value: string | null): string | null => {
    if (value === null) return null;
    const iso = new Date(value).toISOString();
    return iso.replace(/\.\d{3}Z$/, "Z");
};
types.setTypeParser(1184, stripMillis as (v: string) => string);
types.setTypeParser(1114, stripMillis as (v: string) => string);

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
    throw new Error("DATABASE_URL is not set. Copy .env.example to .env and configure it.");
}

export const pool = new Pool({ connectionString });

pool.on("error", (err) => {
    console.error("Unexpected Postgres pool error", err);
});

/**
 * Idempotent schema bootstrap. Safe to call on every boot.
 *
 * Schema mirrors the SwiftData models in lifting/Models.swift. Every table
 * carries `updated_at` (last-write-wins sync cursor) and `deleted_at`
 * (soft-delete tombstone). Deletes never remove rows -- they flip
 * `deleted_at` and bump `updated_at` so offline clients learn about
 * deletions on their next pull.
 */
/**
 * Deterministic UUID for the "legacy" user: a placeholder account that owns
 * any domain data that existed before multi-user auth was introduced. On
 * the first real Apple/Google sign-in the server claims this account by
 * attaching the identity to it (see routes/auth.ts), so existing workouts
 * don't orphan.
 */
export const LEGACY_USER_ID = "00000000-0000-0000-0000-00000000fee1";

export async function migrate(): Promise<void> {
    const client = await pool.connect();
    try {
        await client.query("BEGIN");

        await client.query(`CREATE EXTENSION IF NOT EXISTS "uuid-ossp";`);

        // Auth tables.
        //
        // `users` is intentionally minimal: profile data beyond what's
        // needed for routing belongs in later, unlocked-by-feature tables
        // so we don't end up with a pile of nullable columns here.
        //
        // `auth_identities` keeps one row per (provider, provider_user_id).
        // Splitting it out of `users` means adding a third provider (email
        // link, GitHub, etc.) later is purely additive and never needs a
        // schema change on `users` itself.
        await client.query(`
            CREATE TABLE IF NOT EXISTS users (
                id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
                email         TEXT,
                name          TEXT,
                is_legacy     BOOLEAN      NOT NULL DEFAULT FALSE,
                created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                last_seen_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
            );
        `);

        await client.query(`
            CREATE TABLE IF NOT EXISTS auth_identities (
                id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id           UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                provider          TEXT         NOT NULL CHECK (provider IN ('apple','google')),
                provider_user_id  TEXT         NOT NULL,
                email             TEXT,
                created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                UNIQUE (provider, provider_user_id)
            );
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_auth_identities_user
                ON auth_identities(user_id);
        `);

        // Seed the legacy user so it exists before we backfill FKs below.
        await client.query(
            `INSERT INTO users (id, is_legacy)
             VALUES ($1, TRUE)
             ON CONFLICT (id) DO NOTHING`,
            [LEGACY_USER_ID],
        );

        await client.query(`
            CREATE TABLE IF NOT EXISTS workout_sessions (
                id                        UUID         PRIMARY KEY,
                start_time                TIMESTAMPTZ  NOT NULL,
                end_time                  TIMESTAMPTZ  NOT NULL,
                is_completed              BOOLEAN      NOT NULL DEFAULT FALSE,
                started_from_template_id  UUID,
                updated_at                TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                deleted_at                TIMESTAMPTZ
            );
        `);

        await client.query(`
            CREATE TABLE IF NOT EXISTS exercise_entries (
                id           UUID         PRIMARY KEY,
                session_id   UUID         REFERENCES workout_sessions(id) ON DELETE CASCADE,
                name         TEXT         NOT NULL,
                category     TEXT         NOT NULL,
                "order"      INTEGER      NOT NULL DEFAULT 0,
                updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                deleted_at   TIMESTAMPTZ
            );
        `);

        await client.query(`
            CREATE TABLE IF NOT EXISTS workout_sets (
                id                UUID             PRIMARY KEY,
                exercise_id       UUID             REFERENCES exercise_entries(id) ON DELETE CASCADE,
                weight            DOUBLE PRECISION NOT NULL,
                reps              INTEGER          NOT NULL,
                duration_seconds  INTEGER,
                "order"           INTEGER          NOT NULL DEFAULT 0,
                updated_at        TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
                deleted_at        TIMESTAMPTZ
            );
        `);

        // Migration path for an already-seeded DB created before sync columns
        // existed. ADD COLUMN IF NOT EXISTS is idempotent, so this is safe to
        // run every boot.
        for (const table of [
            "workout_sessions",
            "exercise_entries",
            "workout_sets",
        ]) {
            await client.query(
                `ALTER TABLE ${table}
                    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ`,
            );
        }
        await client.query(
            `ALTER TABLE workout_sessions
                ADD COLUMN IF NOT EXISTS is_completed BOOLEAN NOT NULL DEFAULT FALSE`,
        );

        // Optional duration on a set, for plank/dead-hang/AMRAP-style
        // exercises where reps don't apply. Nullable: legacy rep-based
        // sets (the vast majority) read NULL and the client treats
        // that as "rep-based, ignore time".
        await client.query(
            `ALTER TABLE workout_sets
                ADD COLUMN IF NOT EXISTS duration_seconds INTEGER`,
        );

        // `started_from_template_id` is a weak reference (no FK): it records
        // which template the user started this session from so we can surface
        // "how many sessions came from template X" stats and detect drift
        // between template and actual-logged exercises. Nullable because
        // ad-hoc sessions aren't derived from a template, and because a weak
        // reference avoids upsert failures when a template push silently
        // fails earlier in the sync pipeline (pushTemplates in
        // SyncEngine.swift swallows per-row errors).
        await client.query(
            `ALTER TABLE workout_sessions
                ADD COLUMN IF NOT EXISTS started_from_template_id UUID`,
        );

        // Multi-tenant rollout (idempotent):
        //
        //   1. Add user_id as nullable so existing rows don't violate NOT NULL
        //   2. Backfill any NULLs with the legacy user so ownership is defined
        //   3. Tighten the column to NOT NULL (only if no NULLs remain)
        //
        // The constraint is added via ALTER TABLE ... SET NOT NULL guarded by
        // a pg_attribute check so rerunning after the tighten is a no-op.
        for (const table of [
            "workout_sessions",
            "exercise_entries",
            "workout_sets",
        ]) {
            await client.query(
                `ALTER TABLE ${table}
                    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id)`,
            );
            await client.query(
                `UPDATE ${table} SET user_id = $1 WHERE user_id IS NULL`,
                [LEGACY_USER_ID],
            );
            await client.query(
                `ALTER TABLE ${table} ALTER COLUMN user_id SET NOT NULL`,
            );
        }

        // Workout templates: user-curated blueprints of exercise lists
        // reused across sessions. Same sync/ownership conventions as the
        // session tables so the existing SyncEngine / requireAuth /
        // last-write-wins machinery works uniformly.
        await client.query(`
            CREATE TABLE IF NOT EXISTS workout_templates (
                id           UUID         PRIMARY KEY,
                user_id      UUID         NOT NULL REFERENCES users(id),
                name         TEXT         NOT NULL,
                "order"      INTEGER      NOT NULL DEFAULT 0,
                updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                deleted_at   TIMESTAMPTZ
            );
        `);
        await client.query(`
            CREATE TABLE IF NOT EXISTS template_exercises (
                id           UUID         PRIMARY KEY,
                user_id      UUID         NOT NULL REFERENCES users(id),
                template_id  UUID         REFERENCES workout_templates(id) ON DELETE CASCADE,
                name         TEXT         NOT NULL,
                category     TEXT         NOT NULL,
                "order"      INTEGER      NOT NULL DEFAULT 0,
                updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                deleted_at   TIMESTAMPTZ
            );
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_template_exercises_template
                ON template_exercises(template_id);
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_workout_templates_user_updated
                ON workout_templates(user_id, updated_at);
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_template_exercises_user_updated
                ON template_exercises(user_id, updated_at);
        `);

        // Indexes for common query paths.
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_exercise_entries_session_id
                ON exercise_entries(session_id);
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_workout_sets_exercise_id
                ON workout_sets(exercise_id);
        `);
        // Sync cursor indexes: /sync/changes pages through these. We index
        // (user_id, updated_at) so per-user paginated sync is a single
        // range scan rather than a table scan + filter.
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_workout_sessions_user_updated
                ON workout_sessions(user_id, updated_at);
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_exercise_entries_user_updated
                ON exercise_entries(user_id, updated_at);
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_workout_sets_user_updated
                ON workout_sets(user_id, updated_at);
        `);
        // Template-usage analytics index. Partial because ad-hoc sessions
        // (no template) are the majority and should not bloat the index;
        // the query "how many sessions did user X start from template Y"
        // only cares about non-NULL template IDs.
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_workout_sessions_user_template
                ON workout_sessions(user_id, started_from_template_id)
                WHERE started_from_template_id IS NOT NULL;
        `);

        // User profile: identity, training context, and goals the AI coach
        // folds into its prompt. One row per user (PK is user_id). Every
        // field is nullable so the profile fills in incrementally -- users
        // can skip onboarding, log a few workouts, then add profile data
        // later without a migration. Sync columns match the rest of the
        // schema so SyncEngine treats this uniformly. Body weight lives in
        // a separate time-series table (body_weight_logs) so weight-trend
        // stats are a natural addition; the profile table stores only
        // relatively static identity/training-context data.
        await client.query(`
            CREATE TABLE IF NOT EXISTS user_profiles (
                user_id                   UUID         PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                birth_year                INTEGER,
                sex                       TEXT,
                height_cm                 NUMERIC(5,1),
                experience_level          TEXT,
                training_days_per_week    INTEGER,
                primary_goal              TEXT,
                equipment_access          TEXT,
                preferred_unit            TEXT,
                notes                     TEXT,
                updated_at                TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                deleted_at                TIMESTAMPTZ
            );
        `);
        // Sync cursor index: /sync/changes pages through (user_id, updated_at).
        // Since user_id is the PK we'd normally not need a separate index,
        // but an index on updated_at lets the range scan skip straight to
        // recently-changed rows when we later support cross-user sync ops.
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_user_profiles_updated
                ON user_profiles(updated_at);
        `);

        // Body weight log: time-series of weigh-ins. One row per
        // measurement. `measured_at` is user-provided (they might log
        // yesterday's weight today); `updated_at` is the sync cursor. We
        // keep both so the UI can show weigh-ins chronologically while
        // sync works off modification time. Weight is stored canonically
        // in kg; display converts to lbs per user preference.
        await client.query(`
            CREATE TABLE IF NOT EXISTS body_weight_logs (
                id           UUID         PRIMARY KEY,
                user_id      UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                weight_kg    NUMERIC(6,2) NOT NULL,
                measured_at  TIMESTAMPTZ  NOT NULL,
                notes        TEXT,
                updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                deleted_at   TIMESTAMPTZ
            );
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_body_weight_logs_user_updated
                ON body_weight_logs(user_id, updated_at);
        `);
        // Latest-weight lookup: the AI coach fetches the most recent
        // weigh-in on every prompt build. A descending measured_at index
        // makes that a single index scan.
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_body_weight_logs_user_measured
                ON body_weight_logs(user_id, measured_at DESC)
                WHERE deleted_at IS NULL;
        `);

        // Cache of LLM-generated coach recommendations. Keyed by
        // `user_id` + `subject_id` (a deterministic UUID derived from
        // the coach scope -- whole-workout or per-exercise -- plus goal
        // and unit). Two users on the same goal and unit keep separate
        // caches and can never see each other's data.
        await client.query(`
            CREATE TABLE IF NOT EXISTS coach_analyses (
                id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
                user_id           UUID         REFERENCES users(id) ON DELETE CASCADE,
                subject_type      TEXT         NOT NULL,
                subject_id        UUID         NOT NULL,
                goal              TEXT         NOT NULL,
                unit              TEXT         NOT NULL,
                result            JSONB        NOT NULL,
                model             TEXT         NOT NULL,
                prompt_tokens     INTEGER,
                completion_tokens INTEGER,
                created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                expires_at        TIMESTAMPTZ  NOT NULL
            );
        `);
        // Add user_id and relax the subject_type check for DBs that
        // predate multi-user auth. Then backfill + enforce NOT NULL.
        await client.query(
            `ALTER TABLE coach_analyses
                ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE CASCADE`,
        );
        await client.query(
            `UPDATE coach_analyses SET user_id = $1 WHERE user_id IS NULL`,
            [LEGACY_USER_ID],
        );
        await client.query(
            `ALTER TABLE coach_analyses ALTER COLUMN user_id SET NOT NULL`,
        );
        // Drop the legacy subject_type CHECK constraint (CHECK (subject_type IN ('user')))
        // which would reject per-exercise coach rows from ai/analyze.ts.
        // The constraint's generated name depends on the environment, so
        // we discover it via pg_catalog.
        await client.query(`
            DO $$
            DECLARE
                c_name TEXT;
            BEGIN
                SELECT conname INTO c_name
                FROM pg_constraint
                WHERE conrelid = 'coach_analyses'::regclass
                  AND contype = 'c'
                  AND pg_get_constraintdef(oid) LIKE '%subject_type%';
                IF c_name IS NOT NULL THEN
                    EXECUTE format('ALTER TABLE coach_analyses DROP CONSTRAINT %I', c_name);
                END IF;
            END$$;
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_coach_analyses_user_subject
                ON coach_analyses(user_id, subject_id, created_at DESC);
        `);
        await client.query(`
            CREATE INDEX IF NOT EXISTS idx_coach_analyses_expires_at
                ON coach_analyses(expires_at);
        `);
        // Drop the old (pre user_id) index if it still exists.
        await client.query(`
            DROP INDEX IF EXISTS idx_coach_analyses_subject;
        `);

        await client.query("COMMIT");
    } catch (err) {
        await client.query("ROLLBACK");
        throw err;
    } finally {
        client.release();
    }
}

/** Run a callback inside a transaction, rolling back on any throw. */
export async function withTransaction<T>(
    fn: (client: pg.PoolClient) => Promise<T>,
): Promise<T> {
    const client = await pool.connect();
    try {
        await client.query("BEGIN");
        const result = await fn(client);
        await client.query("COMMIT");
        return result;
    } catch (err) {
        await client.query("ROLLBACK");
        throw err;
    } finally {
        client.release();
    }
}

// Allow `npm run migrate` to execute migrations standalone.
if (import.meta.url === `file://${process.argv[1]}`) {
    migrate()
        .then(() => {
            console.log("Migrations applied");
            return pool.end();
        })
        .catch((err) => {
            console.error("Migration failed", err);
            process.exit(1);
        });
}
