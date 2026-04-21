// Identity exchange endpoints.
//
// The iOS client obtains an ID token from Apple or Google (via
// ASAuthorizationAppleIDProvider or GoogleSignIn-iOS), POSTs it here, and
// receives our own session JWT back. All subsequent API calls carry that
// JWT in `Authorization: Bearer <token>`.
//
// These routes are deliberately mounted BEFORE requireAuth middleware -- a
// user needs a way to acquire a token without already having one.

import { Router } from "express";
import { z } from "zod";
import { asyncHandler, HttpError } from "../middleware.js";
import { parse } from "../schemas.js";
import { issueSessionToken } from "../auth/jwt.js";
import {
    IdentityTokenError,
    verifyIdentityToken,
    type AuthProvider,
} from "../auth/providers.js";
import { findOrCreateUserForIdentity } from "../auth/users.js";

const router = Router();

const ExchangeRequestSchema = z.object({
    // Apple: `authorization.identityToken` (Data, base64-encoded JWT).
    // Google: `GIDSignInResult.user.idToken`.
    identityToken: z.string().min(1).max(8192),
});

const ExchangeResponseSchema = z.object({
    accessToken: z.string(),
    expiresAt: z.string().datetime(),
    user: z.object({
        id: z.string().uuid(),
        email: z.string().nullable(),
        name: z.string().nullable(),
    }),
});
type ExchangeResponse = z.infer<typeof ExchangeResponseSchema>;

async function handleExchange(provider: AuthProvider, identityToken: string): Promise<ExchangeResponse> {
    let claims;
    try {
        claims = await verifyIdentityToken(provider, identityToken);
    } catch (err) {
        if (err instanceof IdentityTokenError) {
            throw new HttpError(err.status, err.message);
        }
        throw err;
    }

    const user = await findOrCreateUserForIdentity(claims);
    const accessToken = await issueSessionToken(user.id);

    // Match the JWT's 7-day expiry so clients know when to re-auth
    // proactively rather than waiting for a 401.
    const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();

    return {
        accessToken,
        expiresAt,
        user: {
            id: user.id,
            email: user.email,
            name: user.name,
        },
    };
}

router.post(
    "/auth/apple",
    asyncHandler(async (req, res) => {
        const dto = parse(ExchangeRequestSchema, req.body);
        const response = await handleExchange("apple", dto.identityToken);
        res.json(response);
    }),
);

router.post(
    "/auth/google",
    asyncHandler(async (req, res) => {
        const dto = parse(ExchangeRequestSchema, req.body);
        const response = await handleExchange("google", dto.identityToken);
        res.json(response);
    }),
);

/**
 * Sign-out is currently a client-side concern: the iOS app deletes the
 * JWT from Keychain and tells the identity provider (Apple/Google) to
 * forget the user. Because we issue stateless JWTs with no server-side
 * session store, there's no revocation list to update. We still expose
 * this endpoint so the client has a single "logout" integration point
 * and so we can add server-side audit logging / push-notification
 * unsubscribe later without a client change.
 */
router.post(
    "/auth/signout",
    asyncHandler(async (_req, res) => {
        res.status(204).send();
    }),
);

export default router;
