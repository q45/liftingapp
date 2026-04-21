// Shared OpenID Connect ID-token verification for Apple and Google.
//
// Both providers issue standard RFC 7519 JWTs signed via RS256 with public
// keys published at well-known JWKs URLs. Verifying an identity token
// therefore reduces to:
//
//   1. Fetch and cache the provider's JWKs (jose handles TTL internally).
//   2. Verify the signature against whichever key's `kid` matches the JWT
//      header.
//   3. Assert the token's `iss` matches the provider and its `aud` matches
//      our own app's client/bundle ID. This is the bit that keeps an
//      attacker from replaying an ID token intended for a different app.
//
// We surface a tiny `IdentityTokenClaims` shape to callers so the rest of
// the server doesn't import jose types directly.

import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";

export type AuthProvider = "apple" | "google";

export interface IdentityTokenClaims {
    provider: AuthProvider;
    providerUserID: string;  // the `sub` claim
    email: string | null;
    emailVerified: boolean;
    name: string | null;     // only Google populates this reliably
}

interface ProviderConfig {
    issuer: string | string[];
    jwksURL: URL;
    audienceEnvVar: string;
    displayName: string;
}

const PROVIDERS: Record<AuthProvider, ProviderConfig> = {
    apple: {
        issuer: "https://appleid.apple.com",
        jwksURL: new URL("https://appleid.apple.com/auth/keys"),
        audienceEnvVar: "APPLE_BUNDLE_ID",
        displayName: "Sign in with Apple",
    },
    google: {
        // Google accepts either issuer per their discovery document.
        issuer: ["https://accounts.google.com", "accounts.google.com"],
        jwksURL: new URL("https://www.googleapis.com/oauth2/v3/certs"),
        audienceEnvVar: "GOOGLE_OAUTH_CLIENT_ID_IOS",
        displayName: "Sign in with Google",
    },
};

// Lazy per-provider JWKs caches. jose's createRemoteJWKSet includes its
// own cooldown + cache, so one instance per provider for the lifetime of
// the process is correct.
const jwksCache = new Map<AuthProvider, ReturnType<typeof createRemoteJWKSet>>();
function jwks(provider: AuthProvider) {
    let set = jwksCache.get(provider);
    if (!set) {
        set = createRemoteJWKSet(PROVIDERS[provider].jwksURL);
        jwksCache.set(provider, set);
    }
    return set;
}

export class IdentityTokenError extends Error {
    status: number;
    constructor(status: number, message: string) {
        super(message);
        this.status = status;
        this.name = "IdentityTokenError";
    }
}

function requiredAudience(provider: AuthProvider): string {
    const cfg = PROVIDERS[provider];
    const aud = process.env[cfg.audienceEnvVar]?.trim();
    if (!aud) {
        throw new IdentityTokenError(
            503,
            `${cfg.audienceEnvVar} is not configured. Set it in server/.env to accept ${cfg.displayName} tokens.`,
        );
    }
    return aud;
}

interface ProviderClaims extends JWTPayload {
    email?: string;
    email_verified?: boolean | string;
    name?: string;
    given_name?: string;
    family_name?: string;
}

function parseName(claims: ProviderClaims): string | null {
    if (typeof claims.name === "string" && claims.name.trim().length > 0) {
        return claims.name.trim();
    }
    const given = typeof claims.given_name === "string" ? claims.given_name : "";
    const family = typeof claims.family_name === "string" ? claims.family_name : "";
    const combined = `${given} ${family}`.trim();
    return combined.length > 0 ? combined : null;
}

/**
 * Verify a third-party ID token and extract the claims we care about.
 *
 * Throws {@link IdentityTokenError} (not bubbling up raw jose errors) so
 * callers can map it to a clean HTTP response without branching on
 * implementation details.
 */
export async function verifyIdentityToken(
    provider: AuthProvider,
    token: string,
): Promise<IdentityTokenClaims> {
    const cfg = PROVIDERS[provider];
    const audience = requiredAudience(provider);

    let payload: ProviderClaims;
    try {
        const result = await jwtVerify<ProviderClaims>(token, jwks(provider), {
            issuer: cfg.issuer,
            audience,
        });
        payload = result.payload;
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new IdentityTokenError(
            401,
            `Invalid ${cfg.displayName} token: ${message}`,
        );
    }

    if (typeof payload.sub !== "string" || payload.sub.length === 0) {
        throw new IdentityTokenError(401, "Token missing sub claim");
    }

    const email =
        typeof payload.email === "string" && payload.email.length > 0
            ? payload.email
            : null;

    // email_verified is typed as boolean in the spec but Google has
    // historically sent it as the string "true"/"false" in some flows.
    const rawVerified = payload.email_verified;
    const emailVerified =
        rawVerified === true || rawVerified === "true";

    return {
        provider,
        providerUserID: payload.sub,
        email,
        emailVerified,
        name: parseName(payload),
    };
}
