// User profile CRUD.
//
// Profile is 1:1 with user, so unlike other resources we don't key the
// URL on an id -- the authenticated user IS the row. `GET /profile`
// returns the caller's profile (or null if they've never saved one);
// `PUT /profile` upserts it. There is no DELETE: soft-deleting a
// profile is equivalent to returning it to the empty state, which PUT
// with all-null fields already accomplishes.
//
// Like the rest of the API, writes are LWW on updated_at, so a stale
// client can't overwrite a newer server copy.

import { Router } from "express";
import { pool } from "../db.js";
import {
    USER_PROFILE_COLUMNS,
    mapUserProfileRow,
    type UserProfileRow,
} from "../mappers.js";
import { asyncHandler, requireUserID } from "../middleware.js";
import { UserProfileSchema, parse } from "../schemas.js";

const router = Router();

/**
 * Fetch the authenticated user's profile. Returns null (not 404) when
 * no profile row exists, so clients can treat "new user" and "user hasn't
 * filled out profile yet" identically -- both cases mean "show an empty
 * profile form".
 */
router.get(
    "/profile",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const { rows } = await pool.query<UserProfileRow>(
            `SELECT ${USER_PROFILE_COLUMNS}
             FROM user_profiles
             WHERE user_id = $1 AND deleted_at IS NULL`,
            [userID],
        );
        const row = rows[0];
        res.json(row ? mapUserProfileRow(row) : null);
    }),
);

/**
 * Upsert the authenticated user's profile. Idempotent; LWW on
 * updated_at so a stale device push can't clobber a fresh edit from
 * another device.
 *
 * Every profile field is nullable so the client can push a partial
 * profile (user only filled out age + goal so far) without padding the
 * missing fields on each request.
 */
router.put(
    "/profile",
    asyncHandler(async (req, res) => {
        const userID = requireUserID(req);
        const dto = parse(UserProfileSchema, req.body);

        await pool.query(
            `INSERT INTO user_profiles (
                user_id, birth_year, sex, height_cm, experience_level,
                training_days_per_week, primary_goal, equipment_access,
                preferred_unit, notes, updated_at, deleted_at
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
             ON CONFLICT (user_id) DO UPDATE SET
                 birth_year              = EXCLUDED.birth_year,
                 sex                     = EXCLUDED.sex,
                 height_cm               = EXCLUDED.height_cm,
                 experience_level        = EXCLUDED.experience_level,
                 training_days_per_week  = EXCLUDED.training_days_per_week,
                 primary_goal            = EXCLUDED.primary_goal,
                 equipment_access        = EXCLUDED.equipment_access,
                 preferred_unit          = EXCLUDED.preferred_unit,
                 notes                   = EXCLUDED.notes,
                 updated_at              = EXCLUDED.updated_at,
                 deleted_at              = EXCLUDED.deleted_at
             WHERE user_profiles.updated_at <= EXCLUDED.updated_at`,
            [
                userID,
                dto.birthYear ?? null,
                dto.sex ?? null,
                dto.heightCm ?? null,
                dto.experienceLevel ?? null,
                dto.trainingDaysPerWeek ?? null,
                dto.primaryGoal ?? null,
                dto.equipmentAccess ?? null,
                dto.preferredUnit ?? null,
                dto.notes ?? null,
                dto.updatedAt,
                dto.deletedAt ?? null,
            ],
        );

        // Re-read so the response reflects whatever the DB actually
        // stored after the LWW guard (and so mapper logic is the single
        // source of truth for the wire shape).
        const { rows } = await pool.query<UserProfileRow>(
            `SELECT ${USER_PROFILE_COLUMNS}
             FROM user_profiles WHERE user_id = $1`,
            [userID],
        );
        const row = rows[0];
        // Safety net: INSERT above should always leave a row unless the
        // LWW predicate rejected it AND there was no prior row. That
        // combination is impossible (LWW only blocks UPDATEs), so if
        // we're here with no row, something more fundamental is broken.
        res.json(row ? mapUserProfileRow(row) : null);
    }),
);

export default router;
