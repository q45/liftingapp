// ClaudeService.swift
// Thin convenience wrapper around `LiftingAPIClient.coachRecommendations`.
//
// Historically this file talked to Anthropic directly with the user's API
// key stored in AppStorage. That's now deprecated: the Anthropic key
// lives server-side only (in server/.env as ANTHROPIC_API_KEY), the iOS
// app carries a session JWT to authenticate with the server, and all LLM
// calls happen via `POST /coach/recommendations`. Keeping this file as
// a thin facade so existing call sites don't have to change call sequence
// -- and so we have one place to add retries / analytics later.

import Foundation

struct ClaudeService {
    /// Ask the server for coach recommendations based on the user's
    /// recent workout history and selected goal.
    ///
    /// Uses AuthManager's authorized client so the request carries the
    /// user's session JWT; when signed out, dev builds still work via
    /// the server's DEV_BYPASS_AUTH escape hatch (prod builds will get
    /// a 401 and the caller's LocalCoach fallback will take over).
    ///
    /// - Parameters:
    ///   - goal: user-facing goal id ("stronger", "bigger", ...).
    ///   - unit: weight unit ("lbs" or "kg").
    ///   - refresh: if true, bypasses the server's response cache.
    /// - Returns: a validated coach response the client can render.
    @MainActor
    static func fetchRecommendations(
        goal: String,
        unit: String,
        refresh: Bool = false,
    ) async throws -> CoachResponseDTO {
        let client = AuthManager.shared.authorizedClient()
        return try await client.coachRecommendations(
            goal: goal,
            unit: unit,
            refresh: refresh,
        )
    }

    /// Ask the server for a recommendation scoped to a single exercise
    /// the user is about to perform. Used by the sparkles button on each
    /// ExerciseCard in WorkoutView.
    @MainActor
    static func fetchExerciseRecommendation(
        exerciseName: String,
        goal: String,
        unit: String,
        refresh: Bool = false,
    ) async throws -> CoachExerciseResponseDTO {
        let client = AuthManager.shared.authorizedClient()
        return try await client.coachExerciseRecommendation(
            exerciseName: exerciseName,
            goal: goal,
            unit: unit,
            refresh: refresh,
        )
    }
}
