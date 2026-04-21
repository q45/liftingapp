// AI coach endpoint. Thin wrapper around ai/analyze.ts.
//
// POST is used (not GET) because calling this has a real side effect:
// on cache miss we make a non-idempotent LLM call that costs money and
// takes ~5 seconds. POST also lets the client pass a `refresh` flag to
// bypass the cache explicitly.

import { Router } from "express";
import {
    AnalyzeError,
    generateCoachRecommendation,
    generateExerciseCoachRecommendation,
} from "../ai/analyze.js";
import { asyncHandler, HttpError, requireUserID } from "../middleware.js";
import {
    CoachExerciseRequestSchema,
    CoachRequestSchema,
    parse,
} from "../schemas.js";

const router = Router();

router.post(
    "/coach/recommendations",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const dto = parse(CoachRequestSchema, req.body);

        try {
            const response = await generateCoachRecommendation({
                userID,
                goal: dto.goal,
                unit: dto.unit,
                forceRefresh: dto.refresh === true,
            });
            res.json(response);
        } catch (err) {
            if (err instanceof AnalyzeError) {
                throw new HttpError(err.status, err.message);
            }
            throw err;
        }
    }),
);

// Per-exercise coach: takes an exerciseName alongside goal/unit and
// returns a single prescription (weight/sets/reps/tip) plus a short
// rationale citing the user's actual history for that lift.
router.post(
    "/coach/exercise-recommendation",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const dto = parse(CoachExerciseRequestSchema, req.body);

        try {
            const response = await generateExerciseCoachRecommendation({
                userID,
                exerciseName: dto.exerciseName,
                goal: dto.goal,
                unit: dto.unit,
                forceRefresh: dto.refresh === true,
            });
            res.json(response);
        } catch (err) {
            if (err instanceof AnalyzeError) {
                throw new HttpError(err.status, err.message);
            }
            throw err;
        }
    }),
);

export default router;
