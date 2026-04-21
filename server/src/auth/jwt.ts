// Server-issued session JWTs.
//
// After the client proves ownership of an Apple/Google identity (see
// providers.ts), we mint our own short-lived JWT that subsequent requests
// carry in `Authorization: Bearer <token>`. Keeping tokens stateless lets
// the API scale horizontally with no shared session store.
//
// We use HS256 with a server-side secret because:
//   - Tokens are verified only by this server (no third-party consumers)
//   - HS256 is ~10x faster than RS256 for the per-request verify hot path
//   - Secret rotation is simpler (one env var, no key distribution)
//
// Tokens live 7 days. On expiry the iOS client transparently re-auths
// with Apple/Google (ASAuthorizationAppleIDProvider.getCredentialState,
// GIDSignIn.restorePreviousSignIn) to get a fresh provider identity
// token and exchanges it for a new session JWT. No refresh-token table.

import { SignJWT, jwtVerify } from "jose";

const DEFAULT_TTL_SECONDS = 7 * 24 * 60 * 60; // 7 days
const ISSUER = "lifting-server";

let cachedSecret: Uint8Array | null = null;
function secret(): Uint8Array {
    if (cachedSecret) return cachedSecret;
    const raw = process.env.JWT_SECRET?.trim();
    if (!raw || raw.length < 32) {
        throw new Error(
            "JWT_SECRET must be set to a >=32 char random string. Add it to server/.env.",
        );
    }
    cachedSecret = new TextEncoder().encode(raw);
    return cachedSecret;
}

export interface SessionClaims {
    userID: string;
    /** Seconds since epoch. */
    exp: number;
}

/**
 * Issue a session JWT for a user. The token's `sub` is the user UUID
 * and `exp` is 7 days from now. No refresh token -- iOS re-auths
 * silently with the identity provider when this expires.
 */
export async function issueSessionToken(userID: string): Promise<string> {
    return await new SignJWT({})
        .setProtectedHeader({ alg: "HS256" })
        .setSubject(userID)
        .setIssuer(ISSUER)
        .setIssuedAt()
        .setExpirationTime(Math.floor(Date.now() / 1000) + DEFAULT_TTL_SECONDS)
        .sign(secret());
}

/**
 * Verify a session JWT and return the claims. Throws on any failure
 * (bad signature, expired, wrong issuer). The caller maps the throw
 * to an HTTP 401 via the auth middleware.
 */
export async function verifySessionToken(token: string): Promise<SessionClaims> {
    const { payload } = await jwtVerify(token, secret(), {
        issuer: ISSUER,
    });
    if (typeof payload.sub !== "string" || payload.sub.length === 0) {
        throw new Error("Session token missing sub claim");
    }
    if (typeof payload.exp !== "number") {
        throw new Error("Session token missing exp claim");
    }
    return { userID: payload.sub, exp: payload.exp };
}
