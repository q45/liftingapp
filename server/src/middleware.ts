import type { NextFunction, Request, RequestHandler, Response } from "express";
import { verifySessionToken } from "./auth/jwt.js";
import { LEGACY_USER_ID } from "./db.js";
import { ValidationError } from "./schemas.js";

// Extend Express's Request with our per-request userId. Set by
// requireAuth() so downstream handlers can just read `req.userId`
// instead of threading it through every function signature.
declare global {
    // eslint-disable-next-line @typescript-eslint/no-namespace
    namespace Express {
        interface Request {
            userId?: string;
        }
    }
}

/**
 * Wrap an async Express handler so thrown errors reach the error middleware.
 * Express 4 does not await handlers; Express 5 does. Using this is harmless
 * either way.
 */
export function asyncHandler<
    P = Record<string, string>,
    ResBody = unknown,
    ReqBody = unknown,
>(
    fn: (
        req: Request<P, ResBody, ReqBody>,
        res: Response<ResBody>,
        next: NextFunction,
    ) => Promise<unknown>,
): RequestHandler<P, ResBody, ReqBody> {
    return (req, res, next) => {
        Promise.resolve(fn(req, res, next)).catch(next);
    };
}

/**
 * Require a UUID param in the URL. Throws a 400 via the HttpError path if
 * missing/invalid.
 */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function requireUUID(value: string | undefined, field = "id"): string {
    if (!value || !UUID_RE.test(value)) {
        throw new HttpError(400, `Invalid UUID for "${field}"`);
    }
    return value;
}

export class HttpError extends Error {
    status: number;
    details?: unknown;
    constructor(status: number, message: string, details?: unknown) {
        super(message);
        this.status = status;
        this.details = details;
        this.name = "HttpError";
    }
}

/**
 * Legacy API-key auth. Kept around so existing ops tooling / smoke tests
 * that still set X-API-Key don't break, but superseded by requireAuth()
 * below for real user-scoped traffic. If API_KEY is unset (common in
 * dev) the middleware short-circuits.
 */
export function apiKeyAuth(expected: string | undefined): RequestHandler {
    return (req, _res, next) => {
        if (!expected) return next();
        const provided = req.header("X-API-Key");
        if (provided !== expected) {
            return next(new HttpError(401, "Invalid or missing API key"));
        }
        next();
    };
}

/**
 * Require a valid session JWT and populate `req.userId`.
 *
 * Dev escape hatch: set `DEV_BYPASS_AUTH=true` in server/.env and any
 * request without a Bearer token is treated as the legacy user. This
 * lets us keep developing iOS locally while Phase 2 (Sign in with Apple
 * / Google on the client) is still in flight. The bypass fails closed in
 * production -- `NODE_ENV=production` forces real auth regardless of
 * the flag.
 */
export function requireAuth(): RequestHandler {
    const bypass =
        process.env.NODE_ENV !== "production" &&
        process.env.DEV_BYPASS_AUTH?.trim().toLowerCase() === "true";

    return async (req, _res, next) => {
        const header = req.header("Authorization");
        const match = header?.match(/^Bearer\s+(.+)$/i);
        const token = match?.[1];

        if (!token) {
            if (bypass) {
                req.userId = LEGACY_USER_ID;
                return next();
            }
            return next(new HttpError(401, "Missing Authorization header"));
        }

        try {
            const claims = await verifySessionToken(token);
            req.userId = claims.userID;
            next();
        } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            next(new HttpError(401, `Invalid session token: ${message}`));
        }
    };
}

/**
 * Retrieve the authenticated user id from a request, throwing a clean
 * 500 if it was never set. Route handlers should call this instead of
 * reading `req.userId` directly so a missing middleware wiring produces
 * an obvious error rather than a silent "all users see each other"
 * security bug.
 */
export function requireUserID(req: Request): string {
    if (!req.userId) {
        throw new HttpError(
            500,
            "req.userId not set -- requireAuth middleware is missing on this route.",
        );
    }
    return req.userId;
}

/** Central error handler. Converts thrown errors into JSON responses. */
export const errorHandler = (
    err: unknown,
    _req: Request,
    res: Response,
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    _next: NextFunction,
): void => {
    if (err instanceof ValidationError) {
        res.status(400).json({
            error: "ValidationError",
            message: "Request body failed validation",
            issues: err.issues,
        });
        return;
    }
    if (err instanceof HttpError) {
        res.status(err.status).json({
            error: err.name,
            message: err.message,
            details: err.details,
        });
        return;
    }
    console.error("Unhandled error", err);
    res.status(500).json({
        error: "InternalServerError",
        message: "Unexpected server error",
    });
};
