import { Router } from "express";
import { pool } from "../db.js";
import { asyncHandler } from "../middleware.js";

const router = Router();

router.get(
    "/health",
    asyncHandler(async (_req, res) => {
        // Liveness + Postgres reachability check.
        await pool.query("SELECT 1");
        res.json({ status: "ok", time: new Date().toISOString() });
    }),
);

export default router;
