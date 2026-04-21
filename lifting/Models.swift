// Models.swift
// SwiftData models + active workout manager backed by SwiftData.
//
// # Sync columns
//
// Every syncable @Model carries three fields (see SyncEngine.swift):
//   updatedAt  -- bumped on every local edit; server compares for LWW.
//   deletedAt  -- soft-delete tombstone. Non-nil rows are filtered out of
//                 views via `isLive` but remain in the store so the delete
//                 can be pushed to the server and mirrored to other devices.
//   needsSync  -- device-local dirty bit. True after every mutation until
//                 SyncEngine successfully pushes to the API. Never sent
//                 over the wire.
//
// Instead of mutating properties directly, call `markDirty()` after any
// edit. Instead of `modelContext.delete()`, call `markDeleted()`. See the
// SyncTrackable protocol below.

import Foundation
import SwiftData
import Observation

// MARK: - SwiftData Models

@Model
final class WorkoutSession {
    var id: UUID
    var startTime: Date
    var endTime: Date
    /// False while the user is actively logging; flipped to true by
    /// `WorkoutManager.finish()`. History views filter to completed rows.
    var isCompleted: Bool
    /// Weak reference to the `WorkoutTemplate` this session was started
    /// from, if any. Nil for ad-hoc sessions. Stored as a UUID rather
    /// than a SwiftData relationship so that (a) deleting the template
    /// doesn't cascade into the session and (b) we can keep the
    /// reference even after the template is soft-deleted, which matters
    /// for longitudinal stats ("sessions derived from now-deleted
    /// templates"). Mirrors `started_from_template_id` server-side.
    var startedFromTemplateID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \ExerciseEntry.session)
    var exercises: [ExerciseEntry]

    var updatedAt: Date
    var deletedAt: Date?
    var needsSync: Bool

    init(startTime: Date = .now, isCompleted: Bool = false) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = startTime
        self.isCompleted = isCompleted
        self.startedFromTemplateID = nil
        self.exercises = []
        self.updatedAt = Date()
        self.deletedAt = nil
        self.needsSync = true
    }

    var totalVolume: Double {
        liveExercises.flatMap(\.liveSets).reduce(0) { $0 + $1.weight * Double($1.reps) }
    }

    var totalSets: Int { liveExercises.reduce(0) { $0 + $1.liveSets.count } }

    var durationString: String {
        let s = Int(endTime.timeIntervalSince(startTime))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

@Model
final class ExerciseEntry {
    var id: UUID
    var name: String
    var category: String
    var order: Int

    /// Inverse of `WorkoutSession.exercises`. Required so each entry
    /// can be synced independently and linked back by parent id.
    var session: WorkoutSession?

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSet.exercise)
    var sets: [WorkoutSet]

    var updatedAt: Date
    var deletedAt: Date?
    var needsSync: Bool

    init(name: String, category: String, order: Int = 0) {
        self.id = UUID()
        self.name = name
        self.category = category
        self.order = order
        self.sets = []
        self.updatedAt = Date()
        self.deletedAt = nil
        self.needsSync = true
    }

    var bestWeight: Double { liveSets.map(\.weight).max() ?? 0 }
    var orderedSets: [WorkoutSet] { liveSets.sorted { $0.order < $1.order } }
}

@Model
final class WorkoutSet {
    var id: UUID
    var weight: Double
    var reps: Int
    var order: Int

    /// Inverse of `ExerciseEntry.sets`.
    var exercise: ExerciseEntry?

    var updatedAt: Date
    var deletedAt: Date?
    var needsSync: Bool

    init(weight: Double, reps: Int, order: Int = 0) {
        self.id = UUID()
        self.weight = weight
        self.reps = reps
        self.order = order
        self.updatedAt = Date()
        self.deletedAt = nil
        self.needsSync = true
    }
}

// MARK: - Workout templates
//
// A template is a reusable workout blueprint -- name + ordered exercise
// list -- that the user can pick from when starting a new session.
// Templates intentionally do NOT store weights/reps/sets: those are per-
// session data and would go stale as the user progresses. The
// SetLoggerView already shows "Previous: X lbs x Y reps" from real
// history, so users get actual-last-session numbers when they log;
// trying to also prescribe numbers in the template would compete with
// that and force us to decide which wins.

@Model
final class WorkoutTemplate {
    var id: UUID
    var name: String
    var order: Int

    @Relationship(deleteRule: .cascade, inverse: \TemplateExercise.template)
    var exercises: [TemplateExercise]

    var updatedAt: Date
    var deletedAt: Date?
    var needsSync: Bool

    init(name: String, order: Int = 0) {
        self.id = UUID()
        self.name = name
        self.order = order
        self.exercises = []
        self.updatedAt = Date()
        self.deletedAt = nil
        self.needsSync = true
    }
}

@Model
final class TemplateExercise {
    var id: UUID
    var name: String
    var category: String
    var order: Int

    /// Inverse of `WorkoutTemplate.exercises`. Lets each exercise sync
    /// independently and reconnect via parent id after pull.
    var template: WorkoutTemplate?

    var updatedAt: Date
    var deletedAt: Date?
    var needsSync: Bool

    init(name: String, category: String, order: Int = 0) {
        self.id = UUID()
        self.name = name
        self.category = category
        self.order = order
        self.updatedAt = Date()
        self.deletedAt = nil
        self.needsSync = true
    }
}

// MARK: - User profile
//
// Identity / training-context data the AI coach folds into its prompt.
// One profile per user (singleton-per-account). Stored as a regular
// @Model so SyncEngine handles writes identically to everything else
// -- markDirty() after an edit, SyncEngine.pushProfile() on next sync.
//
// Every field is optional so users can fill the profile in
// incrementally. Server-side enum values are mirrored as plain strings
// to keep SwiftData migrations trivial (adding a new goal on the
// server doesn't require an enum-case migration on device).

@Model
final class UserProfile {
    /// Singleton marker. There's only ever one row in SwiftData with
    /// this id; it stands in for the server's `user_id` key without
    /// requiring the client to know the authenticated user's UUID.
    /// SyncEngine pushes via PUT /profile (no id in URL).
    static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Always equal to `singletonID`. Stored as @Attribute(.unique) so
    /// we can never accidentally have two profile rows locally.
    @Attribute(.unique) var id: UUID
    var birthYear: Int?
    /// "male" | "female" | "other" | "prefer_not_to_say" -- stored raw
    /// so a drifted client can still persist a newer value. UI maps via
    /// an enum helper in ProfileView.
    var sex: String?
    /// Canonical storage unit is cm; UI converts to ft/in when the
    /// preferred unit is imperial.
    var heightCm: Double?
    /// "novice" | "intermediate" | "advanced"
    var experienceLevel: String?
    var trainingDaysPerWeek: Int?
    /// "strength" | "hypertrophy" | "fat_loss" | "general" | "powerlifting"
    var primaryGoal: String?
    /// "full_gym" | "home_gym" | "bodyweight" | "limited"
    var equipmentAccess: String?
    /// "lbs" | "kg" -- when set, new coach requests default to this
    /// and body weight displays convert accordingly.
    var preferredUnit: String?
    var notes: String?

    var updatedAt: Date
    var deletedAt: Date?
    var needsSync: Bool

    init() {
        self.id = UserProfile.singletonID
        self.birthYear = nil
        self.sex = nil
        self.heightCm = nil
        self.experienceLevel = nil
        self.trainingDaysPerWeek = nil
        self.primaryGoal = nil
        self.equipmentAccess = nil
        self.preferredUnit = nil
        self.notes = nil
        self.updatedAt = Date()
        self.deletedAt = nil
        self.needsSync = false // empty profile shouldn't trigger a push
    }

    /// True when the user has filled in anything at all. UI uses this
    /// to decide whether to show the "empty profile" banner on Coach.
    var hasAnyData: Bool {
        birthYear != nil
            || (sex != nil && !sex!.isEmpty)
            || heightCm != nil
            || (experienceLevel != nil && !experienceLevel!.isEmpty)
            || trainingDaysPerWeek != nil
            || (primaryGoal != nil && !primaryGoal!.isEmpty)
            || (equipmentAccess != nil && !equipmentAccess!.isEmpty)
            || (preferredUnit != nil && !preferredUnit!.isEmpty)
            || (notes != nil && !notes!.isEmpty)
    }
}

// MARK: - Body weight log
//
// Time-series of weigh-ins. Always stored in kg; UI converts for
// display per `UserProfile.preferredUnit`. `measuredAt` is user-
// provided so a backdated weigh-in is a first-class input.

@Model
final class BodyWeightEntry {
    @Attribute(.unique) var id: UUID
    /// Canonical storage unit: kg. Convert in the UI layer.
    var weightKg: Double
    /// When the weigh-in happened, per the user. Distinct from
    /// `updatedAt` (sync cursor), because a user can log yesterday's
    /// weight today and we want chronology to reflect reality.
    var measuredAt: Date
    var notes: String?

    var updatedAt: Date
    var deletedAt: Date?
    var needsSync: Bool

    init(weightKg: Double, measuredAt: Date = .now, notes: String? = nil) {
        self.id = UUID()
        self.weightKg = weightKg
        self.measuredAt = measuredAt
        self.notes = notes
        self.updatedAt = Date()
        self.deletedAt = nil
        self.needsSync = true
    }
}

// MARK: - Sync mutation helpers
//
// Encapsulate dirty/tombstone handling so callers don't have to remember
// to bump updatedAt or needsSync. Single place to update if we ever
// change how dirtiness is tracked.

protocol SyncTrackable: AnyObject {
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
    var needsSync: Bool { get set }
}

extension SyncTrackable {
    /// Call after mutating any persisted property.
    func markDirty(now: Date = Date()) {
        updatedAt = now
        needsSync = true
    }

    /// Soft-delete the record. It remains in the store but is filtered
    /// from views via `isLive` and will propagate to the server on push.
    func markDeleted(now: Date = Date()) {
        deletedAt = now
        updatedAt = now
        needsSync = true
    }

    /// True for records that should appear in the UI.
    var isLive: Bool { deletedAt == nil }
}

extension WorkoutSession: SyncTrackable {}
extension ExerciseEntry: SyncTrackable {}
extension WorkoutSet: SyncTrackable {}
extension WorkoutTemplate: SyncTrackable {}
extension TemplateExercise: SyncTrackable {}
extension UserProfile: SyncTrackable {}
extension BodyWeightEntry: SyncTrackable {}

// SwiftData @Relationship children are unfiltered by default, so soft-
// deleted rows still show up via `session.exercises` / `exercise.sets`.
// These helpers give views a live-only view without filtering everywhere.
extension WorkoutSession {
    var liveExercises: [ExerciseEntry] { exercises.filter(\.isLive) }
    var orderedExercises: [ExerciseEntry] {
        liveExercises.sorted { $0.order < $1.order }
    }
}

extension ExerciseEntry {
    var liveSets: [WorkoutSet] { sets.filter(\.isLive) }
}

extension WorkoutTemplate {
    var liveExercises: [TemplateExercise] { exercises.filter(\.isLive) }
    var orderedExercises: [TemplateExercise] {
        liveExercises.sorted { $0.order < $1.order }
    }
}

// MARK: - Active Workout Manager
//
// Unlike the previous in-memory implementation, this manager operates
// directly on SwiftData. Every set logged is persisted immediately, so a
// crash mid-workout doesn't lose data. The "active" workout is just a
// WorkoutSession with `isCompleted == false`; on app launch the manager
// hydrates itself from whatever unfinished session exists in the store
// (if any). Changes trigger `SyncEngine.scheduleSync()` under the hood.

@Observable
@MainActor
final class WorkoutManager {
    private let modelContext: ModelContext

    /// The in-progress session, if one exists. Nil between workouts.
    /// Setter also updates `isActive` via the computed property.
    private(set) var activeSession: WorkoutSession?

    var isActive: Bool { activeSession != nil }

    /// Preserved for the UI's stopwatch binding. Returns `.now` when no
    /// workout is active, which is a harmless sentinel the timer won't
    /// read because the UI gates on `isActive`.
    var startTime: Date { activeSession?.startTime ?? .now }

    /// Live, ordered exercises of the active session. Empty when no
    /// workout is active.
    var exercises: [ExerciseEntry] {
        activeSession?.orderedExercises ?? []
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.activeSession = Self.recoverActiveSession(context: modelContext)
    }

    /// Look for any previously-started workout that never got finished
    /// (e.g. app crash, force-quit). SwiftData's `#Predicate` macro
    /// doesn't love `!$0.isCompleted` in all Swift versions, so we fetch
    /// and filter in-process -- volume is at most a handful of rows.
    private static func recoverActiveSession(context: ModelContext) -> WorkoutSession? {
        let desc = FetchDescriptor<WorkoutSession>()
        let all = (try? context.fetch(desc)) ?? []
        return all.first { !$0.isCompleted && $0.isLive }
    }

    // MARK: Lifecycle

    func start() {
        // Idempotent: if a session is already active, reuse it instead
        // of creating a duplicate.
        if activeSession != nil { return }
        let session = WorkoutSession(startTime: .now, isCompleted: false)
        modelContext.insert(session)
        try? modelContext.save()
        activeSession = session
        SyncEngine.shared?.scheduleSync()
    }

    func addExercise(name: String, category: String) {
        guard let session = activeSession else { return }
        let entry = ExerciseEntry(
            name: name,
            category: category,
            order: session.liveExercises.count,
        )
        entry.session = session
        modelContext.insert(entry)
        session.markDirty()
        try? modelContext.save()
        SyncEngine.shared?.scheduleSync()
    }

    func addSet(to exercise: ExerciseEntry, weight: Double, reps: Int) {
        let set = WorkoutSet(
            weight: weight,
            reps: reps,
            order: exercise.liveSets.count,
        )
        set.exercise = exercise
        modelContext.insert(set)
        exercise.markDirty()
        try? modelContext.save()
        SyncEngine.shared?.scheduleSync()
    }

    func removeExercise(_ exercise: ExerciseEntry) {
        // Tombstone the exercise and all its sets so the deletion
        // propagates to the server.
        for set in exercise.sets {
            set.markDeleted()
        }
        exercise.markDeleted()
        activeSession?.markDirty()
        try? modelContext.save()
        SyncEngine.shared?.scheduleSync()
    }

    /// Finish the active workout. If no sets were logged the session is
    /// soft-deleted instead, so we don't end up with empty history rows.
    @discardableResult
    func finish() -> WorkoutSession? {
        guard let session = activeSession else { return nil }

        let hasAnySets = session.liveExercises.contains { !$0.liveSets.isEmpty }
        if !hasAnySets {
            // Empty workout: tombstone everything we inserted.
            for ex in session.exercises {
                for s in ex.sets { s.markDeleted() }
                ex.markDeleted()
            }
            session.markDeleted()
            try? modelContext.save()
            activeSession = nil
            SyncEngine.shared?.scheduleSync()
            return nil
        }

        session.endTime = .now
        session.isCompleted = true
        session.markDirty()
        try? modelContext.save()
        activeSession = nil
        SyncEngine.shared?.scheduleSync()
        return session
    }

    /// Abandon the active workout without finishing it. Tombstones
    /// everything and clears the active pointer.
    func cancel() {
        guard let session = activeSession else { return }
        for ex in session.exercises {
            for s in ex.sets { s.markDeleted() }
            ex.markDeleted()
        }
        session.markDeleted()
        try? modelContext.save()
        activeSession = nil
        SyncEngine.shared?.scheduleSync()
    }

    // MARK: Templates
    //
    // Templates are stored independently from sessions -- see the
    // WorkoutTemplate model block for the rationale. These helpers
    // encapsulate the "save a completed session as a template" and
    // "start a new session from a template" flows so the UI layer
    // doesn't have to know about template internals.

    /// Save the given completed session as a reusable template. We copy
    /// just the live exercises (name + category + order) -- sets are
    /// intentionally not copied because templates don't store numbers.
    ///
    /// - Parameters:
    ///   - session: completed session to seed the template from.
    ///   - name: user-entered template name; trimmed and truncated to 60
    ///     chars (matches server CoachRequestSchema's goal cap).
    /// - Returns: the created template, or nil if the session had no
    ///   live exercises to template.
    @discardableResult
    func createTemplate(
        from session: WorkoutSession,
        name rawName: String,
    ) -> WorkoutTemplate? {
        let name = String(
            rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60),
        )
        guard !name.isEmpty else { return nil }

        let exercises = session.orderedExercises
        guard !exercises.isEmpty else { return nil }

        let template = WorkoutTemplate(
            name: name,
            order: nextTemplateOrder(),
        )
        modelContext.insert(template)

        for (index, ex) in exercises.enumerated() {
            let copy = TemplateExercise(
                name: ex.name,
                category: ex.category,
                order: index,
            )
            copy.template = template
            modelContext.insert(copy)
        }

        try? modelContext.save()
        SyncEngine.shared?.scheduleSync()
        return template
    }

    /// Create a brand-new template directly (not derived from a session).
    /// Used by the standalone "Create Template" flow -- not exposed in
    /// the v1 UI but kept here so the capability exists when we add
    /// template editing later.
    @discardableResult
    func createEmptyTemplate(name rawName: String) -> WorkoutTemplate? {
        let name = String(
            rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60),
        )
        guard !name.isEmpty else { return nil }
        let template = WorkoutTemplate(name: name, order: nextTemplateOrder())
        modelContext.insert(template)
        try? modelContext.save()
        SyncEngine.shared?.scheduleSync()
        return template
    }

    /// Start a new workout using the given template's exercise list.
    /// No-op if a workout is already active -- the UI should prevent
    /// this from happening, but we guard anyway so a double-tap doesn't
    /// quietly discard an in-progress session.
    func startFromTemplate(_ template: WorkoutTemplate) {
        guard activeSession == nil else { return }

        let session = WorkoutSession(startTime: .now, isCompleted: false)
        // Stamp the template provenance so server-side stats can answer
        // "which templates actually get used, and how often". This is a
        // weak reference -- we don't care if the template is later
        // deleted; the historical fact that this session came from it
        // remains useful for analytics.
        session.startedFromTemplateID = template.id
        modelContext.insert(session)

        for (index, tex) in template.orderedExercises.enumerated() {
            let entry = ExerciseEntry(
                name: tex.name,
                category: tex.category,
                order: index,
            )
            entry.session = session
            modelContext.insert(entry)
        }

        try? modelContext.save()
        activeSession = session
        SyncEngine.shared?.scheduleSync()
    }

    /// Soft-delete a template and its exercises. Users hit this from
    /// the template picker's swipe-to-delete action.
    func deleteTemplate(_ template: WorkoutTemplate) {
        for ex in template.exercises { ex.markDeleted() }
        template.markDeleted()
        try? modelContext.save()
        SyncEngine.shared?.scheduleSync()
    }

    /// Compute the next `order` value for a freshly created template so
    /// newly-added templates append after existing ones in the picker.
    private func nextTemplateOrder() -> Int {
        let desc = FetchDescriptor<WorkoutTemplate>()
        let all = (try? modelContext.fetch(desc)) ?? []
        let live = all.filter(\.isLive)
        return (live.map(\.order).max() ?? -1) + 1
    }
}
