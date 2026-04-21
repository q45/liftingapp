// Body weight log CRUD.
//
// Time-series of weigh-ins. Weight is stored canonically in kg; the
// client converts for display per the user's preferred_unit profile
// field. `measured_at` is user-provided (so "yesterday's weight logged
// today" is supported); `updated_at` is the sync cursor.
//
// Same LWW + soft-delete semantics as every other record; ownership
// enforced via user_id on every query.

import { Router } from "express";
import { pool } from "../db.js";
import {
    BODY_WEIGHT_LOG_COLUMNS,
    mapBodyWeightLogRow,
    type BodyWeightLogRow,
} from "../mappers.js";
import {
    asyncHandler,
    HttpError,
    requireUserID,
    requireUUID,
} from "../middleware.js";
import { BodyWeightEntrySchema, parse } from "../schemas.js";

const router = Router();

/**
 * GET /body-weight-entries -- caller's live weigh-ins, newest first.
 * Used by the history screen in the iOS app.
 */
router.get(
    "/body-weight-entries",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const { rows } = await pool.query<BodyWeightLogRow>(
            `SELECT ${BODY_WEIGHT_LOG_COLUMNS}
             FROM body_weight_logs
             WHERE user_id = $1 AND deleted_at IS NULL
             ORDER BY measured_at DESC`,
            [userID],
        );
        res.json(rows.map(mapBodyWeightLogRow));
    }),
);

router.get(
    "/body-weight-entries/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const { rows } = await pool.query<BodyWeightLogRow>(
            `SELECT ${BODY_WEIGHT_LOG_COLUMNS}
             FROM body_weight_logs
             WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
            [id, userID],
        );
        const row = rows[0];
        if (!row) throw new HttpError(404, `Body weight entry ${id} not found`);
        res.json(mapBodyWeightLogRow(row));
    }),
);

/**
 * PUT /body-weight-entries/:id -- upsert a single weigh-in.
 */
router.put(
    "/body-weight-entries/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const urlID = requireUUID(req.params.id);
        const dto = parse(BodyWeightEntrySchema, req.body);
        if (dto.id !== urlID) {
            throw new HttpError(400, "URL id does not match body id");
        }

        await pool.query(
            `INSERT INTO body_weight_logs (
                id, user_id, weight_kg, measured_at, notes, updated_at, deleted_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7)
             ON CONFLICT (id) DO UPDATE SET
                 weight_kg   = EXCLUDED.weight_kg,
                 measured_at = EXCLUDED.measured_at,
                 notes       = EXCLUDED.notes,
                 updated_at  = EXCLUDED.updated_at,
                 deleted_at  = EXCLUDED.deleted_at
             WHERE body_weight_logs.updated_at <= EXCLUDED.updated_at
               AND body_weight_logs.user_id = EXCLUDED.user_id`,
            [
                dto.id,
                userID,
                dto.weightKg,
                dto.measuredAt,
                dto.notes ?? null,
                dto.updatedAt,
                dto.deletedAt ?? null,
            ],
        );

        const { rows } = await pool.query<BodyWeightLogRow>(
            `SELECT ${BODY_WEIGHT_LOG_COLUMNS}
             FROM body_weight_logs WHERE id = $1 AND user_id = $2`,
            [dto.id, userID],
        );
        const row = rows[0];
        if (!row) {
            // Same semantics as the other upsert endpoints: either the
            // user_id guard rejected the insert (cross-user UUID collision
            // attempt) or LWW left a foreign row in place. Either way,
            // 404 rather than leak existence.
            throw new HttpError(404, `Body weight entry ${urlID} not found`);
        }
        res.json(mapBodyWeightLogRow(row));
    }),
);

router.delete(
    "/body-weight-entries/:id",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const id = requireUUID(req.params.id);
        const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
        const result = await pool.query(
            `UPDATE body_weight_logs SET deleted_at = $2, updated_at = $2
             WHERE id = $1 AND user_id = $3 AND deleted_at IS NULL`,
            [id, now, userID],
        );
        if (result.rowCount === 0) {
            throw new HttpError(404, `Body weight entry ${id} not found`);
        }
        res.status(204).send();
    }),
);

export default router;
