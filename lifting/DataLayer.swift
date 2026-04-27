// DataLayer.swift
// DTOs + HTTP client for the lifting server.
//
// Wire format matches the Zod schemas in server/src/schemas.ts exactly.
// Every record carries `updatedAt` and `deletedAt` for sync; see
// SyncEngine.swift and server/src/routes/sync.ts for how they're used.

import Foundation
import SwiftData

// MARK: - Sync DTOs

struct WorkoutSetDTO: Codable, Identifiable {
    var id: UUID
    var exerciseID: UUID?
    var weight: Double
    var reps: Int
    /// When non-nil, the set was timed (plank, dead hang, etc.) and
    /// the wire payload carries duration alongside reps. Older clients
    /// that decode this DTO with the field missing fall back to nil
    /// (rep-based), which matches server behavior. Optional default
    /// handled via a custom decoder so the field can be absent on the
    /// wire without `Decodable` complaining.
    var durationSeconds: Int?
    var order: Int
    var updatedAt: Date
    var deletedAt: Date?

    @MainActor
    init(set: WorkoutSet) {
        self.id = set.id
        self.exerciseID = set.exercise?.id
        self.weight = set.weight
        self.reps = set.reps
        self.durationSeconds = set.durationSeconds
        self.order = set.order
        self.updatedAt = set.updatedAt
        self.deletedAt = set.deletedAt
    }

    init(
        id: UUID,
        exerciseID: UUID?,
        weight: Double,
        reps: Int,
        durationSeconds: Int? = nil,
        order: Int,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.weight = weight
        self.reps = reps
        self.durationSeconds = durationSeconds
        self.order = order
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

struct ExerciseEntryDTO: Codable, Identifiable {
    var id: UUID
    var sessionID: UUID?
    var name: String
    var category: String
    var order: Int
    var sets: [WorkoutSetDTO]
    var updatedAt: Date
    var deletedAt: Date?

    @MainActor
    init(entry: ExerciseEntry, includeSets: Bool = false) {
        self.id = entry.id
        self.sessionID = entry.session?.id
        self.name = entry.name
        self.category = entry.category
        self.order = entry.order
        self.sets = includeSets ? entry.sets.map(WorkoutSetDTO.init) : []
        self.updatedAt = entry.updatedAt
        self.deletedAt = entry.deletedAt
    }

    init(
        id: UUID,
        sessionID: UUID?,
        name: String,
        category: String,
        order: Int,
        sets: [WorkoutSetDTO] = [],
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.category = category
        self.order = order
        self.sets = sets
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

struct WorkoutSessionDTO: Codable, Identifiable {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var isCompleted: Bool
    /// Weak reference to the template this session was started from.
    /// Nil for ad-hoc sessions. Omitted from encoded JSON when nil
    /// because the default `JSONEncoder` skips nil optionals, which
    /// matches the Zod schema's `.nullable().optional()` permissiveness.
    var startedFromTemplateID: UUID?
    var exercises: [ExerciseEntryDTO]
    var updatedAt: Date
    var deletedAt: Date?

    @MainActor
    init(session: WorkoutSession, includeChildren: Bool = false) {
        self.id = session.id
        self.startTime = session.startTime
        self.endTime = session.endTime
        self.isCompleted = session.isCompleted
        self.startedFromTemplateID = session.startedFromTemplateID
        self.exercises = includeChildren
            ? session.exercises.map { ExerciseEntryDTO(entry: $0, includeSets: true) }
            : []
        self.updatedAt = session.updatedAt
        self.deletedAt = session.deletedAt
    }

    init(
        id: UUID,
        startTime: Date,
        endTime: Date,
        isCompleted: Bool,
        startedFromTemplateID: UUID? = nil,
        exercises: [ExerciseEntryDTO] = [],
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.isCompleted = isCompleted
        self.startedFromTemplateID = startedFromTemplateID
        self.exercises = exercises
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Template DTOs
//
// Templates mirror sessions/entries but two levels deep (template ->
// exercises) with no sets. Same sync fields, same LWW semantics so
// SyncEngine treats them uniformly.

struct TemplateExerciseDTO: Codable, Identifiable {
    var id: UUID
    var templateID: UUID?
    var name: String
    var category: String
    var order: Int
    var updatedAt: Date
    var deletedAt: Date?

    @MainActor
    init(entry: TemplateExercise) {
        self.id = entry.id
        self.templateID = entry.template?.id
        self.name = entry.name
        self.category = entry.category
        self.order = entry.order
        self.updatedAt = entry.updatedAt
        self.deletedAt = entry.deletedAt
    }

    init(
        id: UUID,
        templateID: UUID?,
        name: String,
        category: String,
        order: Int,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.templateID = templateID
        self.name = name
        self.category = category
        self.order = order
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

struct WorkoutTemplateDTO: Codable, Identifiable {
    var id: UUID
    var name: String
    var order: Int
    var exercises: [TemplateExerciseDTO]
    var updatedAt: Date
    var deletedAt: Date?

    @MainActor
    init(template: WorkoutTemplate, includeChildren: Bool = false) {
        self.id = template.id
        self.name = template.name
        self.order = template.order
        self.exercises = includeChildren
            ? template.exercises.map(TemplateExerciseDTO.init)
            : []
        self.updatedAt = template.updatedAt
        self.deletedAt = template.deletedAt
    }

    init(
        id: UUID,
        name: String,
        order: Int,
        exercises: [TemplateExerciseDTO] = [],
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.exercises = exercises
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Profile + body weight DTOs
//
// Profile is singleton-per-user; no id field on the wire -- the
// authenticated user IS the key. Body-weight entries follow the same
// sync conventions as everything else. Enum string values mirror the
// server's `Sex` / `ExperienceLevel` / `PrimaryGoal` / `EquipmentAccess`
// / `Unit` Zod enums verbatim.

struct UserProfileDTO: Codable {
    var birthYear: Int?
    var sex: String?
    var heightCm: Double?
    var experienceLevel: String?
    var trainingDaysPerWeek: Int?
    var primaryGoal: String?
    var equipmentAccess: String?
    var preferredUnit: String?
    var notes: String?
    var updatedAt: Date
    var deletedAt: Date?

    @MainActor
    init(profile: UserProfile) {
        self.birthYear = profile.birthYear
        self.sex = profile.sex
        self.heightCm = profile.heightCm
        self.experienceLevel = profile.experienceLevel
        self.trainingDaysPerWeek = profile.trainingDaysPerWeek
        self.primaryGoal = profile.primaryGoal
        self.equipmentAccess = profile.equipmentAccess
        self.preferredUnit = profile.preferredUnit
        self.notes = profile.notes
        self.updatedAt = profile.updatedAt
        self.deletedAt = profile.deletedAt
    }

    init(
        birthYear: Int? = nil,
        sex: String? = nil,
        heightCm: Double? = nil,
        experienceLevel: String? = nil,
        trainingDaysPerWeek: Int? = nil,
        primaryGoal: String? = nil,
        equipmentAccess: String? = nil,
        preferredUnit: String? = nil,
        notes: String? = nil,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.birthYear = birthYear
        self.sex = sex
        self.heightCm = heightCm
        self.experienceLevel = experienceLevel
        self.trainingDaysPerWeek = trainingDaysPerWeek
        self.primaryGoal = primaryGoal
        self.equipmentAccess = equipmentAccess
        self.preferredUnit = preferredUnit
        self.notes = notes
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

struct BodyWeightEntryDTO: Codable, Identifiable {
    var id: UUID
    var weightKg: Double
    var measuredAt: Date
    var notes: String?
    var updatedAt: Date
    var deletedAt: Date?

    @MainActor
    init(entry: BodyWeightEntry) {
        self.id = entry.id
        self.weightKg = entry.weightKg
        self.measuredAt = entry.measuredAt
        self.notes = entry.notes
        self.updatedAt = entry.updatedAt
        self.deletedAt = entry.deletedAt
    }

    init(
        id: UUID,
        weightKg: Double,
        measuredAt: Date,
        notes: String? = nil,
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.weightKg = weightKg
        self.measuredAt = measuredAt
        self.notes = notes
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// Aggregate response from `GET /sync/changes?since=...`. Mirrors
/// `SyncChangesSchema` on the server.
struct SyncChangesDTO: Codable {
    var serverTime: Date
    var workoutSessions: [WorkoutSessionDTO]
    var exerciseEntries: [ExerciseEntryDTO]
    var workoutSets: [WorkoutSetDTO]
    var workoutTemplates: [WorkoutTemplateDTO]
    var templateExercises: [TemplateExerciseDTO]
    /// Present only when the user's profile changed since the sync
    /// cursor. Nil means "no profile delta this cycle".
    var userProfile: UserProfileDTO?
    var bodyWeightEntries: [BodyWeightEntryDTO]
}

// MARK: - Coach DTOs

struct CoachRecommendationDTO: Codable, Identifiable, Hashable {
    let exerciseName: String
    let weight: Double
    let sets: Int
    let reps: Int
    let tip: String
    var id: String { exerciseName }
}

struct CoachResultDTO: Codable {
    let summary: String
    let recommendations: [CoachRecommendationDTO]
}

struct CoachRequestDTO: Codable {
    let goal: String
    let unit: String
    let refresh: Bool
}

struct CoachResponseDTO: Codable {
    let createdAt: Date
    let expiresAt: Date
    let cached: Bool
    let model: String
    let goal: String
    let unit: String
    let result: CoachResultDTO
}

// MARK: - Per-exercise coach DTOs
//
// Same wire style as CoachResponseDTO but scoped to a single exercise.
// `result.rationale` is the "why" text the UI shows to build trust;
// `result.recommendation` is the concrete prescription.

struct CoachExerciseResultDTO: Codable {
    let rationale: String
    let recommendation: CoachRecommendationDTO
}

struct CoachExerciseRequestDTO: Codable {
    let exerciseName: String
    let goal: String
    let unit: String
    let refresh: Bool
}

struct CoachExerciseResponseDTO: Codable {
    let createdAt: Date
    let expiresAt: Date
    let cached: Bool
    let model: String
    let goal: String
    let unit: String
    let exerciseName: String
    let result: CoachExerciseResultDTO
}

// MARK: - Auth DTOs
//
// Matches ExchangeRequestSchema / ExchangeResponseSchema in
// server/src/routes/auth.ts. Both /auth/apple and /auth/google use the
// same shape -- the provider is picked via the URL, not a body field,
// so that unauthenticated 4xx responses can be routed to an
// obviously-provider-specific error path.

struct AuthExchangeRequestDTO: Codable {
    /// Apple: the `identityToken` from ASAuthorizationAppleIDCredential
    /// decoded as UTF-8. Google: `GIDGoogleUser.idToken.tokenString`.
    let identityToken: String
}

struct AuthUserDTO: Codable, Equatable {
    let id: UUID
    let email: String?
    let name: String?
}

struct AuthExchangeResponseDTO: Codable {
    let accessToken: String
    let expiresAt: Date
    let user: AuthUserDTO
}

// MARK: - API client

enum LiftingAPIError: Error, LocalizedError {
    case invalidResponse
    case server(statusCode: Int, message: String? = nil)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .server(let code, let message):
            if let message, !message.isEmpty {
                return "Server error \(code): \(message)"
            }
            return "Server error \(code)"
        }
    }
}

/// Shape of JSON error bodies returned by the server (see middleware.ts).
/// Fields are optional because ValidationError bodies differ from HttpError.
private struct LiftingAPIErrorBody: Decodable {
    let error: String?
    let message: String?
}

struct LiftingAPIClient {
    var baseURL: URL
    var apiKey: String?
    /// User session JWT issued by `POST /auth/{apple,google}`. When set,
    /// it's attached as `Authorization: Bearer <jwt>` on every request.
    /// Carried alongside (not replacing) `apiKey` because the legacy
    /// shared API-key check still runs first in the server middleware
    /// chain.
    var authToken: String?

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        baseURL: URL,
        apiKey: String? = nil,
        authToken: String? = nil,
        session: URLSession = .shared,
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.authToken = authToken
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    /// Compute the default base URL: env override for the scheme, else
    /// localhost:3000. For a physical device on the same LAN, set the
    /// `LIFTING_API_URL` scheme env var to your Mac's IP.
    static var defaultBaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["LIFTING_API_URL"],
           let url = URL(string: override) {
            return url
        }
        if let stored = KeychainHelper.read(key: KeychainHelper.serverURLKey),
           let url = URL(string: stored) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }

    // MARK: Auth endpoints
    //
    // These are the only calls the client makes without a Bearer token.
    // The server responds with a session JWT the client stores in the
    // Keychain (see AuthManager.swift) and attaches to subsequent
    // requests via `authToken`.

    func exchangeAppleIdentityToken(_ identityToken: String) async throws -> AuthExchangeResponseDTO {
        let body = AuthExchangeRequestDTO(identityToken: identityToken)
        return try await send("auth/apple", method: "POST", body: body)
    }

    func exchangeGoogleIdentityToken(_ identityToken: String) async throws -> AuthExchangeResponseDTO {
        let body = AuthExchangeRequestDTO(identityToken: identityToken)
        return try await send("auth/google", method: "POST", body: body)
    }

    /// Best-effort server-side signout. Client must still clear its own
    /// token; server-side is a no-op today but exists so audit / push
    /// unsubscribe can land later without a client change.
    func signOut() async throws {
        try await sendEmpty("auth/signout", method: "POST")
    }

    // MARK: Sync endpoints

    func fetchChanges(since: Date?) async throws -> SyncChangesDTO {
        var queryItems: [URLQueryItem] = []
        if let since {
            queryItems.append(URLQueryItem(
                name: "since",
                value: ISO8601DateFormatter().string(from: since),
            ))
        }
        return try await get("sync/changes", query: queryItems)
    }

    func upsertSession(_ dto: WorkoutSessionDTO) async throws -> WorkoutSessionDTO {
        try await send("workout-sessions/\(dto.id)", method: "PUT", body: dto)
    }

    func upsertExercise(_ dto: ExerciseEntryDTO) async throws -> ExerciseEntryDTO {
        try await send("exercise-entries/\(dto.id)", method: "PUT", body: dto)
    }

    func upsertSet(_ dto: WorkoutSetDTO) async throws -> WorkoutSetDTO {
        try await send("workout-sets/\(dto.id)", method: "PUT", body: dto)
    }

    func deleteSession(id: UUID) async throws {
        try await sendEmpty("workout-sessions/\(id)", method: "DELETE")
    }

    func deleteExercise(id: UUID) async throws {
        try await sendEmpty("exercise-entries/\(id)", method: "DELETE")
    }

    func deleteSet(id: UUID) async throws {
        try await sendEmpty("workout-sets/\(id)", method: "DELETE")
    }

    // MARK: Template endpoints

    func upsertTemplate(_ dto: WorkoutTemplateDTO) async throws -> WorkoutTemplateDTO {
        try await send("workout-templates/\(dto.id)", method: "PUT", body: dto)
    }

    func upsertTemplateExercise(_ dto: TemplateExerciseDTO) async throws -> TemplateExerciseDTO {
        try await send("template-exercises/\(dto.id)", method: "PUT", body: dto)
    }

    func deleteTemplate(id: UUID) async throws {
        try await sendEmpty("workout-templates/\(id)", method: "DELETE")
    }

    func deleteTemplateExercise(id: UUID) async throws {
        try await sendEmpty("template-exercises/\(id)", method: "DELETE")
    }

    // MARK: Profile + body weight endpoints
    //
    // `GET /profile` returns the caller's profile or null (not 404) so
    // the client can treat "new user" and "unfilled profile" as the
    // same empty state. `PUT /profile` is idempotent (LWW server-side).

    /// Returns the profile for the authenticated user, or nil if they
    /// haven't filled one in yet.
    func fetchProfile() async throws -> UserProfileDTO? {
        try await getOptional("profile")
    }

    @discardableResult
    func upsertProfile(_ dto: UserProfileDTO) async throws -> UserProfileDTO {
        try await send("profile", method: "PUT", body: dto)
    }

    func upsertBodyWeightEntry(_ dto: BodyWeightEntryDTO) async throws -> BodyWeightEntryDTO {
        try await send("body-weight-entries/\(dto.id)", method: "PUT", body: dto)
    }

    func deleteBodyWeightEntry(id: UUID) async throws {
        try await sendEmpty("body-weight-entries/\(id)", method: "DELETE")
    }

    // MARK: Coach endpoint

    /// Generate or fetch a cached coach recommendation. Pass `refresh: true`
    /// to bypass the server-side cache. First uncached call typically
    /// takes 3-8 seconds; cached calls are instant.
    /// Short timeout for user-facing coach requests. URLSession.shared
    /// defaults to 60 seconds, which makes "server is down" feel
    /// indistinguishable from "broken" -- the coach sheet sits on its
    /// spinner for a full minute before ExerciseCoachSheet's catch block
    /// finally falls back to LocalCoach.
    ///
    /// 12s covers Anthropic's typical 3-8s cache-miss response with
    /// headroom for slower networks, and fails fast when the server is
    /// unreachable so the offline fallback kicks in quickly. Tune via
    /// LIFTING_COACH_TIMEOUT env var for debugging.
    private static let coachTimeoutSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["LIFTING_COACH_TIMEOUT"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
        return 12
    }()

    func coachRecommendations(
        goal: String,
        unit: String,
        refresh: Bool = false,
    ) async throws -> CoachResponseDTO {
        let body = CoachRequestDTO(goal: goal, unit: unit, refresh: refresh)
        return try await send(
            "coach/recommendations",
            method: "POST",
            body: body,
            timeout: Self.coachTimeoutSeconds,
        )
    }

    /// Fetch a single-exercise recommendation. Used by the per-exercise
    /// "AI Coach" button on each ExerciseCard during an active workout.
    func coachExerciseRecommendation(
        exerciseName: String,
        goal: String,
        unit: String,
        refresh: Bool = false,
    ) async throws -> CoachExerciseResponseDTO {
        let body = CoachExerciseRequestDTO(
            exerciseName: exerciseName,
            goal: goal,
            unit: unit,
            refresh: refresh,
        )
        return try await send(
            "coach/exercise-recommendation",
            method: "POST",
            body: body,
            timeout: Self.coachTimeoutSeconds,
        )
    }

    // MARK: - Transport

    private func sendEmpty(_ path: String, method: String) async throws {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LiftingAPIError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw LiftingAPIError.server(
                statusCode: http.statusCode,
                message: Self.extractErrorMessage(from: data),
            )
        }
    }

    private func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
    ) async throws -> Response {
        var request = URLRequest(url: url(for: path, query: query))
        request.httpMethod = "GET"
        applyAuth(to: &request)
        return try await perform(request)
    }

    /// Variant of `get` that treats a JSON `null` response body as
    /// Swift `nil`. Used by `GET /profile` which can legitimately
    /// return `null` when the user hasn't filled in a profile yet --
    /// decoding a non-optional `UserProfileDTO` from `null` would
    /// otherwise throw.
    private func getOptional<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
    ) async throws -> Response? {
        var request = URLRequest(url: url(for: path, query: query))
        request.httpMethod = "GET"
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiftingAPIError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw LiftingAPIError.server(
                statusCode: httpResponse.statusCode,
                message: Self.extractErrorMessage(from: data),
            )
        }
        // Trim whitespace so "  null  " still reads as null.
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "null" { return nil }
        return try decoder.decode(Response.self, from: data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body,
        timeout: TimeInterval? = nil,
    ) async throws -> Response {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try encoder.encode(body)
        if let timeout {
            // Per-request timeout overrides URLSession.shared's 60s default.
            // URLRequest's timeoutInterval is the max idle time waiting for
            // a response; on a TCP connect refused this resolves instantly,
            // on a host-unreachable it bounds the wait at `timeout` seconds.
            request.timeoutInterval = timeout
        }
        return try await perform(request)
    }

    private func applyAuth(to request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiftingAPIError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw LiftingAPIError.server(
                statusCode: httpResponse.statusCode,
                message: Self.extractErrorMessage(from: data),
            )
        }

        return try decoder.decode(Response.self, from: data)
    }

    /// Best-effort extraction of a human-readable message from the server's
    /// error body. Server errors are JSON (`{ error, message, ... }`); fall
    /// back to the raw string if decoding fails. Nil if the body is empty.
    private static func extractErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let body = try? JSONDecoder().decode(LiftingAPIErrorBody.self, from: data),
           let message = body.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        return nil
    }

    /// Build a URL from `baseURL`, a path, and optional query items.
    ///
    /// We avoid `URL.appending(path:)` because on several iOS versions it
    /// percent-encodes embedded slashes in the path argument. For example
    /// `baseURL.appending(path: "sync/changes")` becomes `.../sync%2Fchanges`
    /// which the server responds to with 404. `URLComponents` assembles
    /// the URL correctly, including properly URL-encoded query values.
    private func url(
        for path: String,
        query: [URLQueryItem] = [],
    ) -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false,
        ) else {
            return baseURL
        }

        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/" + trimmed
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url ?? baseURL
    }
}
