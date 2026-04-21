// Prompt construction for the coach recommendations endpoint.
//
// Pattern:
//   1. A system message that declares the assistant's role, grounding
//      rules (cite numbers from data only), and the exact JSON schema.
//   2. A user message containing the data as JSON. Keeps prompts small
//      and easy to log.
//
// We deliberately avoid Claude's tool-use mode. Prompting for raw JSON +
// validating with Zod on the way back is cheaper and, for this schema,
// reliable in practice. If hallucination of keys becomes an issue we can
// swap to tool-use without changing callers.

import type {
    BodyWeightEntryDTO,
    UserProfileDTO,
    WorkoutSessionDTO,
} from "../schemas.js";

/**
 * Distill a session down to the fields the LLM can reason over. Strips
 * server/internal metadata to keep the prompt small and focused.
 */
function sessionPayload(session: WorkoutSessionDTO, unit: "lbs" | "kg") {
    const exercises = (session.exercises ?? [])
        .filter((e) => !e.deletedAt)
        .sort((a, b) => a.order - b.order)
        .map((e) => ({
            name: e.name,
            category: e.category,
            sets: (e.sets ?? [])
                .filter((s) => !s.deletedAt)
                .sort((a, b) => a.order - b.order)
                .map((s) => ({ weight: s.weight, reps: s.reps, unit })),
        }));
    return {
        date: session.endTime.slice(0, 10),
        exercises,
    };
}

/**
 * Compact, LLM-friendly view of the user's profile. Nulls are stripped
 * so the JSON only carries fields the user has actually filled in --
 * avoids the prompt dedicating tokens to "sex: null, birthYear: null,
 * ...". Body weight is converted to the user's preferred unit so the
 * prompt's units stay internally consistent.
 *
 * Returns null when the user has zero profile data AND no weight
 * logged; the prompt builder inserts "athlete: null" in that case and
 * the SYSTEM message already instructs the model to handle cold-start
 * recommendations.
 */
function athletePayload(
    profile: UserProfileDTO | null,
    latestWeight: BodyWeightEntryDTO | null,
    unit: "lbs" | "kg",
): Record<string, unknown> | null {
    const out: Record<string, unknown> = {};
    const now = new Date();
    const currentYear = now.getUTCFullYear();

    if (profile?.birthYear) {
        // Approximate age from birth year (off by up to 1y without DOB;
        // sufficient for programming context).
        out.age = currentYear - profile.birthYear;
    }
    if (profile?.sex && profile.sex !== "prefer_not_to_say") {
        out.sex = profile.sex;
    }
    if (profile?.heightCm) {
        out.height_cm = profile.heightCm;
    }
    if (profile?.experienceLevel) {
        out.experience_level = profile.experienceLevel;
    }
    if (profile?.trainingDaysPerWeek) {
        out.training_days_per_week = profile.trainingDaysPerWeek;
    }
    if (profile?.primaryGoal) {
        out.primary_goal = profile.primaryGoal;
    }
    if (profile?.equipmentAccess) {
        out.equipment_access = profile.equipmentAccess;
    }
    if (profile?.notes && profile.notes.trim()) {
        // `notes` carries user-provided constraints (injuries, exercises
        // to avoid). Passed through verbatim, capped via the schema.
        out.constraints_notes = profile.notes.trim();
    }

    if (latestWeight) {
        // Server stores kg canonically; convert for the prompt so units
        // match everything else in the payload.
        const value =
            unit === "lbs"
                ? Math.round(latestWeight.weightKg * 2.20462 * 10) / 10
                : latestWeight.weightKg;
        out.body_weight = { value, unit, measured_at: latestWeight.measuredAt.slice(0, 10) };
    }

    return Object.keys(out).length === 0 ? null : out;
}

// Shared rules block appended to the SYSTEM message of both prompt
// builders. Isolated so prompt tweaks stay in one place and can't
// drift between builders.
const ATHLETE_CONTEXT_RULES = `
ATHLETE CONTEXT
The input may include an "athlete" object describing the user's age, sex, height, body weight, experience level, training days/week, primary goal, equipment access, and free-text constraints (injuries, exercises to avoid). When present, use it to:
- Bias progression step size by experience_level: novice = +2.5 lbs / +1.25 kg or +1 rep; intermediate = +5 lbs / +2.5 kg; advanced = +2.5 lbs / +1.25 kg or same weight +1 rep (smaller jumps, slower progression).
- Respect equipment_access strictly. Never prescribe a barbell movement to "bodyweight"; never prescribe a squat rack movement to "home_gym" unless the exercise already appears in their history.
- Treat constraints_notes as HARD CONSTRAINTS. If the user says "no overhead pressing", do not recommend any overhead exercise, even if it appears in their history.
- Let primary_goal override the goal-shaped defaults when they conflict.
- If the athlete object is absent or sparse, fall back to conservative defaults and make no assumptions.
Never repeat the athlete context back to the user in summaries or tips -- use it internally only.`;

export function buildCoachPrompt(params: {
    goal: string;
    unit: "lbs" | "kg";
    recentSessions: WorkoutSessionDTO[];
    profile: UserProfileDTO | null;
    latestWeight: BodyWeightEntryDTO | null;
}): { system: string; user: string } {
    const history = params.recentSessions.map((s) => sessionPayload(s, params.unit));
    const athlete = athletePayload(params.profile, params.latestWeight, params.unit);

    const system = `You are an expert strength coach. The user logs workouts in an iOS app and wants concrete recommendations for their next session.

INPUT
You will receive JSON with:
- goal: the user's training goal (e.g. "stronger", "hypertrophy")
- unit: weight unit the user prefers ("lbs" or "kg")
- athlete: optional object describing the user (age, sex, experience, goal, equipment, constraints, body weight). May be null.
- sessions: the user's last N completed workout sessions with every exercise, weight, and rep count
${ATHLETE_CONTEXT_RULES}

OUTPUT
Respond with a single JSON object and nothing else -- no prose before or after, no markdown code fences. The JSON must match this schema EXACTLY:

{
  "summary": "1-2 sentence overview of the user's recent training, cited with specific numbers.",
  "recommendations": [
    {
      "exerciseName": "exact exercise name from input history",
      "weight": <number, in the user's chosen unit>,
      "sets": <integer 1-10>,
      "reps": <integer 1-30>,
      "tip": "single short actionable cue, <=15 words, no fluff"
    }
  ]
}

RULES
- Only recommend exercises that appear in the user's recent sessions. Do not invent new exercises.
- Use the user's unit for all weight values.
- Base weight recommendations on the user's actual recent top set; a 2-5% jump is typical for strength, same-weight more reps for hypertrophy.
- Never invent historical numbers. Every number in summary must come from the input.
- Keep tips specific: "drive through heels on lockout" is ok; "push harder" is not.
- Never prescribe rest times, tempos, or RPE unless directly asked.
- Never diagnose or imply injury.
- Return valid JSON that parses with JSON.parse. No trailing commas.`;

    const user = JSON.stringify(
        {
            goal: params.goal,
            unit: params.unit,
            athlete,
            sessions: history,
            session_count: history.length,
        },
        null,
        2,
    );

    return { system, user };
}

/**
 * Build the prompt for a single-exercise recommendation. Filters the
 * user's recent sessions down to just entries matching `exerciseName`
 * (case-insensitive) so the LLM can reason purely about that lift's
 * progression without being distracted by unrelated work.
 */
export function buildExerciseCoachPrompt(params: {
    exerciseName: string;
    goal: string;
    unit: "lbs" | "kg";
    recentSessions: WorkoutSessionDTO[];
    profile: UserProfileDTO | null;
    latestWeight: BodyWeightEntryDTO | null;
}): { system: string; user: string } {
    const target = params.exerciseName.trim().toLowerCase();
    const athlete = athletePayload(params.profile, params.latestWeight, params.unit);

    // Distill each session into just the sets for this one exercise,
    // preserving date order (most recent first) so the LLM can see
    // progression at a glance. Sessions with no matching exercise are
    // dropped entirely.
    const history = params.recentSessions
        .map((s) => {
            const matching = (s.exercises ?? [])
                .filter((e) => !e.deletedAt && e.name.trim().toLowerCase() === target)
                .flatMap((e) =>
                    (e.sets ?? [])
                        .filter((set) => !set.deletedAt)
                        .sort((a, b) => a.order - b.order)
                        .map((set) => ({
                            weight: set.weight,
                            reps: set.reps,
                            unit: params.unit,
                        })),
                );
            if (matching.length === 0) return null;
            return {
                date: s.endTime.slice(0, 10),
                sets: matching,
            };
        })
        .filter((x): x is NonNullable<typeof x> => x !== null);

    const system = `You are an expert strength coach. The user is about to perform a specific exercise in their current workout and wants a concrete prescription for today.

INPUT
You will receive JSON with:
- exerciseName: the exact name of the exercise they're about to do
- goal: the user's training goal (e.g. "stronger", "hypertrophy")
- unit: weight unit ("lbs" or "kg")
- athlete: optional object describing the user (age, sex, experience, goal, equipment, constraints, body weight). May be null.
- history: their recent sessions for THIS exercise only, newest first, with every set's weight and reps
${ATHLETE_CONTEXT_RULES}

OUTPUT
Respond with a single JSON object and nothing else -- no prose before or after, no markdown code fences. Schema EXACTLY:

{
  "rationale": "1-2 short sentences citing specific numbers from history explaining the prescription (e.g. 'Last session you hit 3x5 @ 185. Progressing +5 lbs for strength.'). <=280 chars.",
  "recommendation": {
    "exerciseName": "<echo the input exerciseName exactly>",
    "weight": <number, in the user's chosen unit>,
    "sets": <integer 1-10>,
    "reps": <integer 1-30>,
    "tip": "one short actionable cue, <=15 words"
  }
}

RULES
- Base the prescription on the user's actual recent top working set for this exercise.
- Typical progression: strength goal -> +2.5-5% weight or +1 rep at same weight; hypertrophy -> same weight, hit top of 8-12 rep range; endurance -> lighter, higher reps.
- If history is empty or sparse, pick a conservative starting prescription and say so in the rationale.
- Use the user's unit. Round weights to the nearest plate (2.5 lbs or 1.25 kg).
- Every number in the rationale must come from the input history. Do not invent numbers.
- Keep tips specific to this exercise (e.g. "drive through heels on lockout", not "push harder").
- Never diagnose or imply injury.
- Return valid JSON that parses with JSON.parse. No trailing commas.`;

    const user = JSON.stringify(
        {
            exerciseName: params.exerciseName,
            goal: params.goal,
            unit: params.unit,
            athlete,
            history,
            history_session_count: history.length,
        },
        null,
        2,
    );

    return { system, user };
}
