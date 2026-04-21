// User lookup + creation from a verified third-party identity.
//
// The claim-legacy flow is worth calling out: before real auth existed,
// all domain rows were owned by a fixed "legacy" user so backfilled
// FKs had somewhere to point (see LEGACY_USER_ID in db.ts). On the first
// successful sign-in we attach the incoming provider identity to that
// legacy user and flip `is_legacy=false` -- atomically, inside the same
// INSERT ... ON CONFLICT transaction as the identity row -- so a real
// person ends up owning the pre-auth workouts instead of creating a
// separate empty account. This only fires once; subsequent sign-ins for
// other providers create their own account per the user's stated policy
// of "no cross-provider linking".

import type { PoolClient } from "pg";
import { pool, LEGACY_USER_ID } from "../db.js";
import type { IdentityTokenClaims } from "./providers.js";

export interface UserRow {
    id: string;
    email: string | null;
    name: string | null;
    is_legacy: boolean;
    created_at: string;
    last_seen_at: string;
}

type Queryable = Pick<PoolClient, "query">;

async function findExistingUserForIdentity(
    db: Queryable,
    claims: IdentityTokenClaims,
): Promise<UserRow | null> {
    const { rows } = await db.query<UserRow>(
        `SELECT u.id, u.email, u.name, u.is_legacy, u.created_at, u.last_seen_at
         FROM auth_identities i
         JOIN users u ON u.id = i.user_id
         WHERE i.provider = $1 AND i.provider_user_id = $2
         LIMIT 1`,
        [claims.provider, claims.providerUserID],
    );
    return rows[0] ?? null;
}

async function claimLegacyUser(
    db: Queryable,
    claims: IdentityTokenClaims,
): Promise<UserRow | null> {
    // Guard: the legacy user is only claimable once and only if it has
    // no attached identities yet. If a prior sign-in already claimed it
    // (even from a different provider) we leave it alone and fall
    // through to the "create new user" path.
    const { rows } = await db.query<{ already_claimed: boolean }>(
        `SELECT EXISTS(
            SELECT 1 FROM auth_identities WHERE user_id = $1
         ) AS already_claimed
         FROM users WHERE id = $1`,
        [LEGACY_USER_ID],
    );
    if (rows.length === 0 || rows[0]!.already_claimed) return null;

    const update = await db.query<UserRow>(
        `UPDATE users SET
            email        = COALESCE($2, email),
            name         = COALESCE($3, name),
            is_legacy    = FALSE,
            last_seen_at = NOW()
         WHERE id = $1
         RETURNING id, email, name, is_legacy, created_at, last_seen_at`,
        [LEGACY_USER_ID, claims.email, claims.name],
    );
    return update.rows[0] ?? null;
}

async function createUser(
    db: Queryable,
    claims: IdentityTokenClaims,
): Promise<UserRow> {
    const { rows } = await db.query<UserRow>(
        `INSERT INTO users (email, name)
         VALUES ($1, $2)
         RETURNING id, email, name, is_legacy, created_at, last_seen_at`,
        [claims.email, claims.name],
    );
    const row = rows[0];
    if (!row) throw new Error("Failed to insert user");
    return row;
}

async function attachIdentity(
    db: Queryable,
    userID: string,
    claims: IdentityTokenClaims,
): Promise<void> {
    // ON CONFLICT DO NOTHING because the caller already checked for an
    // existing identity -- this belt-and-suspenders guard just prevents
    // a race between two concurrent first-time sign-ins from the same
    // provider_user_id from crashing.
    await db.query(
        `INSERT INTO auth_identities (user_id, provider, provider_user_id, email)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (provider, provider_user_id) DO NOTHING`,
        [userID, claims.provider, claims.providerUserID, claims.email],
    );
}

/**
 * Resolve the user for a freshly verified identity.
 *
 * 1. If an identity row already exists for this (provider, sub), return
 *    its user -- this is the steady-state sign-in path.
 * 2. Otherwise, if the legacy user still exists unclaimed, attach this
 *    identity to it so any pre-auth workouts are owned by the first
 *    real user (see file header for rationale).
 * 3. Otherwise, create a fresh user and attach the identity.
 *
 * Always bumps `last_seen_at` so we can eventually prune inactive accounts.
 */
export async function findOrCreateUserForIdentity(
    claims: IdentityTokenClaims,
): Promise<UserRow> {
    const client = await pool.connect();
    try {
        await client.query("BEGIN");

        // 1. Steady-state: identity already exists.
        const existing = await findExistingUserForIdentity(client, claims);
        if (existing) {
            await client.query(
                `UPDATE users SET last_seen_at = NOW(),
                                  email = COALESCE($2, email),
                                  name  = COALESCE($3, name)
                 WHERE id = $1`,
                [existing.id, claims.email, claims.name],
            );
            await client.query("COMMIT");
            return { ...existing, last_seen_at: new Date().toISOString() };
        }

        // 2. First real sign-in: claim the legacy user if available.
        const claimed = await claimLegacyUser(client, claims);
        if (claimed) {
            await attachIdentity(client, claimed.id, claims);
            await client.query("COMMIT");
            return claimed;
        }

        // 3. Otherwise, brand-new user.
        const fresh = await createUser(client, claims);
        await attachIdentity(client, fresh.id, claims);
        await client.query("COMMIT");
        return fresh;
    } catch (err) {
        await client.query("ROLLBACK");
        throw err;
    } finally {
        client.release();
    }
}
