import cors from "cors";
import express from "express";
import morgan from "morgan";

import {
    apiKeyAuth,
    errorHandler,
    HttpError,
    requireAuth,
} from "./middleware.js";
import authRouter from "./routes/auth.js";
import bodyWeightEntriesRouter from "./routes/bodyWeightEntries.js";
import coachRouter from "./routes/coach.js";
import exerciseEntriesRouter from "./routes/exerciseEntries.js";
import healthRouter from "./routes/health.js";
import profileRouter from "./routes/profile.js";
import syncRouter from "./routes/sync.js";
import workoutSessionsRouter from "./routes/workoutSessions.js";
import workoutSetsRouter from "./routes/workoutSets.js";
import workoutTemplatesRouter from "./routes/workoutTemplates.js";

export function createApp(config: {
    corsOrigin: string;
    apiKey?: string;
}): express.Express {
    const app = express();

    app.disable("x-powered-by");
    app.use(express.json({ limit: "1mb" }));
    app.use(
        cors({
            origin: config.corsOrigin === "*" ? true : config.corsOrigin.split(","),
        }),
    );
    app.use(morgan("tiny"));

    // Health check and auth exchange are mounted *before* requireAuth so
    // monitoring can always reach health, and unauthenticated clients
    // have a way to acquire a session token in the first place.
    app.use(healthRouter);

    // Legacy shared API key is still accepted everywhere (optional,
    // no-op if API_KEY is unset). Kept to avoid breaking existing ops
    // tooling; user-scoped requests layer session JWT auth on top of it.
    app.use(apiKeyAuth(config.apiKey));

    app.use(authRouter);

    // Everything past this line requires a valid session JWT (or the
    // DEV_BYPASS_AUTH env escape hatch in non-production).
    app.use(requireAuth());

    app.use(workoutSessionsRouter);
    app.use(exerciseEntriesRouter);
    app.use(workoutSetsRouter);
    app.use(workoutTemplatesRouter);
    app.use(profileRouter);
    app.use(bodyWeightEntriesRouter);
    app.use(syncRouter);
    app.use(coachRouter);

    app.use((req, _res, next) => {
        next(new HttpError(404, `Route not found: ${req.method} ${req.path}`));
    });

    app.use(errorHandler);

    return app;
}
