// LocalCoach.swift
// On-device fallback for per-exercise coach recommendations.
//
// When the server (or Anthropic) is unreachable, we compute a reasonable
// recommendation locally from SwiftData history instead of showing an
// error. This isn't trying to replace the LLM -- it just applies well-
// known progressive-overload heuristics to the user's last session so
// they can keep logging even when offline.
//
// Online behavior is unchanged; `ExerciseCoachSheet` calls the server
// first and only falls through to this on a thrown error.
//
// Shipping an Anthropic API key on-device is explicitly rejected as a
// fallback -- keys on user devices are extractable and would require
// every user to manage their own billing. See ClaudeService.swift for
// the rationale.

import Foundation
import SwiftData

// MARK: - Unified outcome model
//
// Both the server and local paths produce the same shape so the sheet
// UI doesn't care where the recommendation came from. `source` tells
// the UI which badge to render (Cached / Offline / nothing).

struct ExerciseCoachOutcome: Equatable {
    let weight: Double
    let sets: Int
    let reps: Int
    let tip: String
    let rationale: String
    let source: Source

    enum Source: Equatable {
        case server(cached: Bool)
        case offline
    }
}

extension ExerciseCoachOutcome {
    /// Bridge from the server DTO so the UI can consume a single type.
    init(serverResponse: CoachExerciseResponseDTO) {
        let rec = serverResponse.result.recommendation
        self.init(
            weight: rec.weight,
            sets: rec.sets,
            reps: rec.reps,
            tip: rec.tip,
            rationale: serverResponse.result.rationale,
            source: .server(cached: serverResponse.cached),
        )
    }
}

// MARK: - Whole-workout outcome
//
// Mirror of ExerciseCoachOutcome but at the workout level. Both server
// and local paths produce this shape so CoachView doesn't branch on the
// source when rendering -- only on the source badge.

struct WorkoutCoachOutcome: Equatable {
    let summary: String
    let recommendations: [CoachRecommendationDTO]
    /// Echoes the unit the recommendation weights were computed in, so
    /// the view can render "lbs" / "kg" badges without threading it
    /// through from the view's @AppStorage separately.
    let unit: String
    let source: Source

    enum Source: Equatable {
        case server(cached: Bool)
        case offline
    }
}

extension WorkoutCoachOutcome {
    /// Bridge from the server DTO.
    init(serverResponse: CoachResponseDTO) {
        self.init(
            summary: serverResponse.result.summary,
            recommendations: serverResponse.result.recommendations,
            unit: serverResponse.unit,
            source: .server(cached: serverResponse.cached),
        )
    }
}

// MARK: - LocalCoach

enum LocalCoach {
    /// Compute an offline recommendation for one exercise.
    ///
    /// - Parameters:
    ///   - exerciseName: exact name from the card (matched case-insensitively).
    ///   - goal: user-facing goal id ("stronger", "bigger", "leaner", "endurance").
    ///   - unit: "lbs" or "kg".
    ///   - context: SwiftData context used to fetch past sessions.
    @MainActor
    static func recommend(
        exerciseName: String,
        goal: String,
        unit: String,
        context: ModelContext,
    ) -> ExerciseCoachOutcome {
        let history = lookupHistory(exerciseName: exerciseName, context: context)
        let params = GoalParams.forGoal(goal)
        let core = recommendCore(
            exerciseName: exerciseName,
            history: history,
            unit: unit,
            params: params,
        )
        return ExerciseCoachOutcome(
            weight: core.weight,
            sets: core.sets,
            reps: core.reps,
            tip: core.tip,
            rationale: core.rationale,
            source: .offline,
        )
    }

    /// Compute a whole-workout offline recommendation.
    ///
    /// Strategy:
    ///   1. Pull the user's most recent completed sessions (cap at 10).
    ///   2. Rank exercises by (a) frequency across sessions, then
    ///      (b) recency of most recent appearance, to favor lifts the
    ///      user actually trains. Ad-hoc one-offs drop to the bottom.
    ///   3. Take the top N (4-6 depending on goal) as the "workout".
    ///   4. Apply per-exercise progression to each, reusing the same
    ///      math the per-exercise coach uses.
    ///   5. Build a summary citing real numbers so the user trusts
    ///      the output.
    ///
    /// Returns an outcome with `source = .offline` so the UI can badge
    /// it as such. If the user has zero completed sessions the caller
    /// should never reach this (CoachView gates on that), but we still
    /// degrade gracefully by returning an empty recommendations list
    /// and a plain-English summary.
    @MainActor
    static func recommendWorkout(
        goal: String,
        unit: String,
        context: ModelContext,
    ) -> WorkoutCoachOutcome {
        let params = GoalParams.forGoal(goal)
        let sessions = recentCompletedSessions(context: context, limit: 10)

        if sessions.isEmpty {
            return WorkoutCoachOutcome(
                summary: "Log at least one completed workout so the coach has something to work from.",
                recommendations: [],
                unit: unit,
                source: .offline,
            )
        }

        // Rank exercises: frequency (count of sessions they appear in)
        // is the primary key; recency (most recent session index,
        // lower = more recent) breaks ties. Using session-index rather
        // than set-count means a single high-volume workout doesn't
        // dominate rankings -- we want the lifts the user does
        // consistently.
        struct Ranked {
            let name: String
            let category: String
            /// Most recent history for this exercise across the pulled
            /// sessions. Nil is impossible since rankings are built from
            /// history; typed optional to satisfy the compiler.
            let history: [HistoryEntry]
            let frequency: Int
            let recencyIndex: Int // 0 = newest session
        }

        var byName: [String: Ranked] = [:]
        for (sessionIndex, session) in sessions.enumerated() {
            for ex in session.liveExercises {
                let key = ex.name.trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty else { continue }
                let entry = historyEntry(for: ex, endTime: session.endTime)
                guard let entry else { continue }

                if let existing = byName[key] {
                    byName[key] = Ranked(
                        name: existing.name,
                        category: existing.category,
                        history: existing.history + [entry],
                        frequency: existing.frequency + 1,
                        recencyIndex: min(existing.recencyIndex, sessionIndex),
                    )
                } else {
                    byName[key] = Ranked(
                        name: ex.name,
                        category: ex.category,
                        history: [entry],
                        frequency: 1,
                        recencyIndex: sessionIndex,
                    )
                }
            }
        }

        // Sort newest-first on the per-exercise history so `.first`
        // means last session. Ordering upstream is already newest-first
        // because recentCompletedSessions sorts that way, but being
        // explicit avoids a silent bug if that ever changes.
        let ranked = byName.values
            .map { r in
                Ranked(
                    name: r.name,
                    category: r.category,
                    history: r.history.sorted(by: { $0.date > $1.date }),
                    frequency: r.frequency,
                    recencyIndex: r.recencyIndex,
                )
            }
            .sorted { a, b in
                if a.frequency != b.frequency { return a.frequency > b.frequency }
                return a.recencyIndex < b.recencyIndex
            }

        // Goal-scaled target count: strength/powerlifting-style users
        // want fewer exercises with more focus; hypertrophy/endurance
        // do more variety. Clamp to what history actually supports.
        let targetCount: Int
        switch goal {
        case "stronger": targetCount = 4
        case "bigger":   targetCount = 6
        case "leaner":   targetCount = 5
        case "endurance": targetCount = 5
        default:         targetCount = 5
        }
        let picked = Array(ranked.prefix(min(targetCount, ranked.count)))

        let recommendations: [CoachRecommendationDTO] = picked.map { r in
            let core = recommendCore(
                exerciseName: r.name,
                history: r.history,
                unit: unit,
                params: params,
            )
            return CoachRecommendationDTO(
                exerciseName: r.name,
                weight: core.weight,
                sets: core.sets,
                reps: core.reps,
                tip: core.tip,
            )
        }

        // Summary cites real numbers (session count, lift count) so the
        // user can tell this is derived from their actual data, not
        // generic advice. Deliberately short -- the row-level tips carry
        // the specificity.
        let sessionWord = sessions.count == 1 ? "session" : "sessions"
        let topNames = picked.prefix(3).map(\.name).joined(separator: ", ")
        let summary: String = {
            if topNames.isEmpty {
                return "Reviewed your last \(sessions.count) \(sessionWord)."
            }
            return "Based on your last \(sessions.count) \(sessionWord) — your most frequent lifts are \(topNames). Progression applied for \(goalLabel(goal))."
        }()

        return WorkoutCoachOutcome(
            summary: summary,
            recommendations: recommendations,
            unit: unit,
            source: .offline,
        )
    }

    // MARK: - Shared per-exercise core
    //
    // Factored out so `recommend(exerciseName:...)` and `recommendWorkout`
    // share exactly one progression code path. Returns the numeric
    // prescription plus the rendered tip and rationale strings. The
    // `source` field is attached by callers (both paths currently tag
    // themselves as `.offline`).

    private struct RecommendationCore {
        let weight: Double
        let sets: Int
        let reps: Int
        let tip: String
        let rationale: String
    }

    private static func recommendCore(
        exerciseName: String,
        history: [HistoryEntry],
        unit: String,
        params: GoalParams,
    ) -> RecommendationCore {
        // Cold start: no prior sets. Conservative starting
        // prescription, rationale names the cold-start condition.
        guard let last = history.first else {
            let starting = startingPrescription(
                for: exerciseName,
                unit: unit,
                params: params,
            )
            return RecommendationCore(
                weight: starting.weight,
                sets: starting.sets,
                reps: starting.reps,
                tip: params.coldStartTip,
                rationale: "No prior \(exerciseName.lowercased()) logged. Starting conservatively — adjust up or down based on how the first set feels.",
            )
        }

        let prescription = progress(from: last, unit: unit, params: params)
        let lastSummary = "\(formatWeight(last.topWeight)) \(unit) × \(last.topReps)"
        let rationale = "Last \(exerciseName.lowercased()): \(last.setCount) set\(last.setCount == 1 ? "" : "s") @ \(lastSummary). \(params.offlineRationaleSuffix)"

        return RecommendationCore(
            weight: prescription.weight,
            sets: prescription.sets,
            reps: prescription.reps,
            tip: params.tipForExercise(exerciseName),
            rationale: rationale,
        )
    }

    /// Human-readable goal label used in the workout summary.
    private static func goalLabel(_ id: String) -> String {
        switch id {
        case "stronger":  return "strength"
        case "bigger":    return "hypertrophy"
        case "leaner":    return "fat loss"
        case "endurance": return "endurance"
        default:          return "general"
        }
    }

    // MARK: - Goal parameters
    //
    // Plain struct of numbers so each goal's tuning lives in one place
    // instead of being scattered through conditionals.

    private struct GoalParams {
        /// Fraction to add to working weight each session (e.g. 0.025 = +2.5%).
        let weightProgressPct: Double
        /// Rep target range (low, high). We progress reps toward `high`
        /// before adding weight, for hypertrophy/endurance goals.
        let repRange: ClosedRange<Int>
        /// Default set count when the user has no prior history.
        let defaultSets: Int
        /// Rep count to use for cold starts (no history).
        let coldStartReps: Int
        /// Rationale suffix explaining the progression direction.
        let offlineRationaleSuffix: String
        /// Tip used when we have no exercise-specific coaching string.
        let genericTip: String
        /// Tip used on a cold start.
        let coldStartTip: String

        func tipForExercise(_ name: String) -> String {
            // A handful of known-good cues per big lift; everything else
            // gets the goal-level generic tip.
            let lower = name.lowercased()
            if lower.contains("bench") { return "Tuck elbows ~45°, drive through the mid-foot." }
            if lower.contains("squat") { return "Brace hard, knees track over toes." }
            if lower.contains("deadlift") { return "Bar over mid-foot, lats tight before pull." }
            if lower.contains("overhead") || lower.contains("press") { return "Glutes + abs locked, bar path straight up." }
            if lower.contains("row") { return "Pull to the sternum, squeeze shoulder blades." }
            return genericTip
        }

        static func forGoal(_ id: String) -> GoalParams {
            switch id {
            case "stronger":
                return GoalParams(
                    weightProgressPct: 0.025,
                    repRange: 3...5,
                    defaultSets: 5,
                    coldStartReps: 5,
                    offlineRationaleSuffix: "Adding ~2.5% for strength progression.",
                    genericTip: "Slow on the way down, explosive on the way up.",
                    coldStartTip: "Pick a weight you can hit for 5 clean reps.",
                )
            case "bigger":
                return GoalParams(
                    weightProgressPct: 0.0,
                    repRange: 8...12,
                    defaultSets: 4,
                    coldStartReps: 10,
                    offlineRationaleSuffix: "Same weight — add a rep before adding weight.",
                    genericTip: "Control the eccentric, full range of motion.",
                    coldStartTip: "Pick a weight you can hit for 10 reps with form intact.",
                )
            case "leaner":
                return GoalParams(
                    weightProgressPct: 0.0,
                    repRange: 12...15,
                    defaultSets: 3,
                    coldStartReps: 12,
                    offlineRationaleSuffix: "Same weight, push reps — short rests between sets.",
                    genericTip: "Keep rest short (60s), maintain tempo.",
                    coldStartTip: "Light enough for 12 reps + short rests.",
                )
            case "endurance":
                return GoalParams(
                    weightProgressPct: 0.0,
                    repRange: 15...25,
                    defaultSets: 3,
                    coldStartReps: 15,
                    offlineRationaleSuffix: "Higher reps — add 2 if last set felt easy.",
                    genericTip: "Steady breathing, no full lockout pauses.",
                    coldStartTip: "Light weight, aim for 15+ clean reps.",
                )
            default:
                // Unknown goal: treat as hypertrophy (safe middle ground).
                return forGoal("bigger")
            }
        }
    }

    // MARK: - History lookup

    /// One session's worth of data for one exercise, distilled to the
    /// numbers the progression rules need.
    private struct HistoryEntry {
        let date: Date
        let topWeight: Double
        let topReps: Int // reps performed at topWeight
        let setCount: Int
    }

    @MainActor
    private static func lookupHistory(
        exerciseName: String,
        context: ModelContext,
    ) -> [HistoryEntry] {
        let target = exerciseName.trimmingCharacters(in: .whitespaces).lowercased()
        let sessions = recentCompletedSessions(context: context, limit: 30)

        return sessions.compactMap { session in
            let matches = session.liveExercises.filter {
                $0.name.trimmingCharacters(in: .whitespaces).lowercased() == target
            }
            guard let ex = matches.first else { return nil }
            return historyEntry(for: ex, endTime: session.endTime)
        }
    }

    /// Fetch the caller's most recent completed, non-deleted sessions.
    /// Shared between per-exercise and whole-workout code paths so
    /// history bounds stay consistent.
    @MainActor
    private static func recentCompletedSessions(
        context: ModelContext,
        limit: Int,
    ) -> [WorkoutSession] {
        var descriptor = FetchDescriptor<WorkoutSession>(
            sortBy: [SortDescriptor(\.endTime, order: .reverse)],
        )
        descriptor.fetchLimit = limit
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.isLive && $0.isCompleted }
    }

    /// Distill one ExerciseEntry (from a specific session) into a
    /// HistoryEntry. Returns nil if the entry has no live sets --
    /// callers treat that as "this exercise didn't happen in this
    /// session" and skip.
    @MainActor
    private static func historyEntry(
        for exercise: ExerciseEntry,
        endTime: Date,
    ) -> HistoryEntry? {
        let sets = exercise.liveSets
        guard !sets.isEmpty else { return nil }

        // Top set = heaviest weight; break ties with reps.
        let top = sets.max(by: { a, b in
            a.weight < b.weight || (a.weight == b.weight && a.reps < b.reps)
        })!

        return HistoryEntry(
            date: endTime,
            topWeight: top.weight,
            topReps: top.reps,
            setCount: sets.count,
        )
    }

    // MARK: - Progression math

    private struct Prescription {
        let weight: Double
        let sets: Int
        let reps: Int
    }

    private static func progress(
        from last: HistoryEntry,
        unit: String,
        params: GoalParams,
    ) -> Prescription {
        // Strength: bump weight, keep reps at bottom of range. Hypertrophy/
        // endurance: if last set was below the top of the range, add a
        // rep at the same weight; otherwise add a small amount of weight
        // and reset reps to the bottom of the range.
        if params.weightProgressPct > 0 {
            let bumped = last.topWeight * (1 + params.weightProgressPct)
            let rounded = roundToPlate(bumped, unit: unit)
            // Ensure we moved at least one plate step up even with tiny
            // percentages on light weights.
            let step = smallestPlateStep(for: unit)
            let next = max(last.topWeight + step, rounded)
            return Prescription(
                weight: next,
                sets: max(3, last.setCount),
                reps: params.repRange.lowerBound,
            )
        } else if last.topReps < params.repRange.upperBound {
            return Prescription(
                weight: last.topWeight,
                sets: params.defaultSets,
                reps: min(last.topReps + 1, params.repRange.upperBound),
            )
        } else {
            let step = smallestPlateStep(for: unit)
            return Prescription(
                weight: roundToPlate(last.topWeight + step, unit: unit),
                sets: params.defaultSets,
                reps: params.repRange.lowerBound,
            )
        }
    }

    private static func startingPrescription(
        for exerciseName: String,
        unit: String,
        params: GoalParams,
    ) -> Prescription {
        // Ballpark opener per exercise category. These are deliberately
        // conservative -- most users will bump up on set 2. A wrong guess
        // here is easy to fix; a too-heavy guess can cause injury.
        let lower = exerciseName.lowercased()
        let isKg = unit == "kg"

        let weight: Double
        if lower.contains("deadlift") {
            weight = isKg ? 60 : 135
        } else if lower.contains("squat") {
            weight = isKg ? 40 : 95
        } else if lower.contains("bench") || lower.contains("overhead") || lower.contains("press") {
            weight = isKg ? 20 : 45
        } else if lower.contains("row") || lower.contains("pulldown") {
            weight = isKg ? 30 : 70
        } else if lower.contains("curl") || lower.contains("raise") || lower.contains("fly") {
            weight = isKg ? 8 : 20
        } else if lower.contains("pushdown") || lower.contains("skull") {
            weight = isKg ? 12 : 30
        } else {
            weight = isKg ? 20 : 45
        }

        return Prescription(
            weight: weight,
            sets: params.defaultSets,
            reps: params.coldStartReps,
        )
    }

    // MARK: - Rounding
    //
    // Gyms use plate steps of 2.5 lb or 1.25 kg (smallest fractional
    // plates most racks have). Machines usually step in 5 lb / 2.5 kg
    // increments. Rounding to the plate floor avoids "add 3.7 lbs"
    // nonsense in the UI.

    private static func smallestPlateStep(for unit: String) -> Double {
        unit == "kg" ? 2.5 : 5.0
    }

    private static func roundToPlate(_ weight: Double, unit: String) -> Double {
        let step = smallestPlateStep(for: unit)
        return (weight / step).rounded() * step
    }

    private static func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(w))"
            : String(format: "%.1f", w)
    }
}
