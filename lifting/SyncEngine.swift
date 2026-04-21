// SyncEngine.swift
// Bidirectional sync between the local SwiftData store and the lifting API.
//
// # Architecture
//
// Offline-first:
//
// - **Writes are local-first.** When the user edits, views / WorkoutManager
//   mutate SwiftData directly (via `markDirty()` / `markDeleted()` on the
//   model) and then fire-and-forget a call to `SyncEngine.shared.syncNow()`
//   through `scheduleSync()`. The UI never waits on the network.
//
// - **Reads are local-only.** Views use `@Query` against SwiftData. On app
//   launch and pull-to-refresh we `pull()` from the server and merge
//   changes into the store. SwiftUI re-renders automatically.
//
// - **Conflict resolution is last-write-wins by `updatedAt`.** Whoever
//   stamps the record most recently (by wall-clock time) wins. Imperfect
//   for concurrent edits on two devices, but industry-standard for
//   small-team / single-user apps.
//
// - **Deletes are soft.** Both client and server mark records with a
//   `deletedAt` tombstone. Offline devices learn about deletions on their
//   next pull.
//
// Persisted cursor: single timestamp in `UserDefaults`. On each pull we
// fetch `updated_at > lastSyncTime` and advance the cursor to the
// server's reported `serverTime`.
//
// # Not implemented yet (roadmap)
//
// - Retry with exponential backoff on transient failures
// - Push deduplication (user edits then reverts still pushes)
// - WebSocket / SSE for real-time pushes from server to device
// - Per-field conflict resolution (we overwrite the whole record)

import Foundation
import SwiftData

@MainActor
final class SyncEngine {

    // MARK: - Configuration

    /// Shared instance wired up by `liftingApp`. Nil until `configure` runs.
    static var shared: SyncEngine?

    private let api: LiftingAPIClient
    private let modelContext: ModelContext
    private let userDefaults: UserDefaults

    private static let lastSyncKey = "SyncEngine.lastSyncTime"

    /// Exposed so UI can show "Last synced N min ago" if desired.
    private(set) var lastSyncTime: Date? {
        didSet {
            if let date = lastSyncTime {
                userDefaults.set(date, forKey: Self.lastSyncKey)
            } else {
                userDefaults.removeObject(forKey: Self.lastSyncKey)
            }
        }
    }

    /// True while a sync is in flight. Prevents concurrent syncs from
    /// stomping on each other.
    private(set) var isSyncing = false

    init(
        api: LiftingAPIClient,
        modelContext: ModelContext,
        userDefaults: UserDefaults = .standard,
    ) {
        self.api = api
        self.modelContext = modelContext
        self.userDefaults = userDefaults
        self.lastSyncTime = userDefaults.object(forKey: Self.lastSyncKey) as? Date
    }

    // MARK: - Public entry points

    /// One-shot sync: push local changes, then pull remote changes.
    /// Push before pull so our edits aren't overwritten by a stale
    /// server copy in the same round-trip. If `push` fails the `pull`
    /// still runs -- we want fresh server data even if uploads are broken.
    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do { try await push() } catch {
            print("⚠️ SyncEngine push failed: \(error)")
        }
        do { try await pull() } catch {
            print("⚠️ SyncEngine pull failed: \(error)")
        }
    }

    /// Convenience: spawn `syncNow` detached. Call from SwiftUI after any
    /// save -- UI continues immediately; sync runs in the background.
    func scheduleSync() {
        Task { await syncNow() }
    }

    /// Reset the sync cursor. The next `pull()` refetches everything.
    /// Useful for debugging.
    func resetCursor() {
        lastSyncTime = nil
    }

    // MARK: - Push
    //
    // Upload every locally-modified record. Parents first (sessions) so
    // when children reference them server-side the FK target exists.
    //
    // Tombstones ride on the same PUT endpoints -- the server stores
    // whatever `deletedAt` we send. Separate DELETE endpoints exist for
    // the case where the client never wrote the record locally.

    func push() async throws {
        // Parents before children: templates before their exercises,
        // sessions before their entries, entries before sets. That way
        // when a child references its parent_id server-side, the FK
        // target already exists.
        try await pushTemplates()
        try await pushTemplateExercises()
        try await pushSessions()
        try await pushExercises()
        try await pushSets()
        // Profile + body-weight are independent of the session tree;
        // order among them doesn't matter. Kept after the main tree so
        // a profile push failure doesn't block session sync.
        try await pushProfile()
        try await pushBodyWeightEntries()
    }

    private func pushTemplates() async throws {
        let descriptor = FetchDescriptor<WorkoutTemplate>(
            predicate: #Predicate { $0.needsSync == true },
        )
        let dirty = try modelContext.fetch(descriptor)

        for template in dirty {
            let dto = WorkoutTemplateDTO(template: template, includeChildren: false)
            do {
                _ = try await api.upsertTemplate(dto)
                template.needsSync = false
            } catch {
                print("⚠️ Failed to push template \(template.id): \(error)")
            }
        }
        try? modelContext.save()
    }

    private func pushTemplateExercises() async throws {
        let descriptor = FetchDescriptor<TemplateExercise>(
            predicate: #Predicate { $0.needsSync == true },
        )
        let dirty = try modelContext.fetch(descriptor)

        for entry in dirty {
            let dto = TemplateExerciseDTO(entry: entry)
            do {
                _ = try await api.upsertTemplateExercise(dto)
                entry.needsSync = false
            } catch {
                print("⚠️ Failed to push template exercise \(entry.id): \(error)")
            }
        }
        try? modelContext.save()
    }

    private func pushSessions() async throws {
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.needsSync == true },
        )
        let dirty = try modelContext.fetch(descriptor)

        for session in dirty {
            // Build shallow DTO: children sync independently via their
            // own needsSync flags.
            let dto = WorkoutSessionDTO(session: session, includeChildren: false)
            do {
                _ = try await api.upsertSession(dto)
                session.needsSync = false
            } catch {
                print("⚠️ Failed to push session \(session.id): \(error)")
            }
        }
        try? modelContext.save()
    }

    private func pushExercises() async throws {
        let descriptor = FetchDescriptor<ExerciseEntry>(
            predicate: #Predicate { $0.needsSync == true },
        )
        let dirty = try modelContext.fetch(descriptor)

        for entry in dirty {
            let dto = ExerciseEntryDTO(entry: entry, includeSets: false)
            do {
                _ = try await api.upsertExercise(dto)
                entry.needsSync = false
            } catch {
                print("⚠️ Failed to push exercise \(entry.id): \(error)")
            }
        }
        try? modelContext.save()
    }

    private func pushSets() async throws {
        let descriptor = FetchDescriptor<WorkoutSet>(
            predicate: #Predicate { $0.needsSync == true },
        )
        let dirty = try modelContext.fetch(descriptor)

        for set in dirty {
            let dto = WorkoutSetDTO(set: set)
            do {
                _ = try await api.upsertSet(dto)
                set.needsSync = false
            } catch {
                print("⚠️ Failed to push set \(set.id): \(error)")
            }
        }
        try? modelContext.save()
    }

    /// Profile is singleton-per-user. Fetch the (at most one) dirty
    /// profile and PUT it if present. The server's URL is /profile (no
    /// id) because the authenticated user is the key.
    private func pushProfile() async throws {
        let descriptor = FetchDescriptor<UserProfile>(
            predicate: #Predicate { $0.needsSync == true },
        )
        let dirty = try modelContext.fetch(descriptor)
        for profile in dirty {
            let dto = UserProfileDTO(profile: profile)
            do {
                _ = try await api.upsertProfile(dto)
                profile.needsSync = false
            } catch {
                print("⚠️ Failed to push profile: \(error)")
            }
        }
        try? modelContext.save()
    }

    private func pushBodyWeightEntries() async throws {
        let descriptor = FetchDescriptor<BodyWeightEntry>(
            predicate: #Predicate { $0.needsSync == true },
        )
        let dirty = try modelContext.fetch(descriptor)
        for entry in dirty {
            let dto = BodyWeightEntryDTO(entry: entry)
            do {
                _ = try await api.upsertBodyWeightEntry(dto)
                entry.needsSync = false
            } catch {
                print("⚠️ Failed to push body-weight entry \(entry.id): \(error)")
            }
        }
        try? modelContext.save()
    }

    // MARK: - Pull
    //
    // Fetch every record the server changed since our cursor and
    // reconcile into SwiftData. Parents before children (so children
    // can wire up their parent relationships).

    func pull() async throws {
        let changes = try await api.fetchChanges(since: lastSyncTime)

        applySessions(changes.workoutSessions)
        applyExercises(changes.exerciseEntries)
        applySets(changes.workoutSets)
        applyTemplates(changes.workoutTemplates)
        applyTemplateExercises(changes.templateExercises)
        if let dto = changes.userProfile {
            applyProfile(dto)
        }
        applyBodyWeightEntries(changes.bodyWeightEntries)

        try? modelContext.save()
        lastSyncTime = changes.serverTime
    }

    // MARK: - Reconciliation

    /// Apply a remote DTO to the local store.
    ///
    /// Returns the local model instance (existing or freshly inserted).
    /// Skips the merge entirely if the local copy is newer than the
    /// incoming one (client-side LWW guard mirroring the server's
    /// UPDATE predicate).
    private func upsertLocal<Model: PersistentModel & SyncTrackable>(
        id: UUID,
        remoteUpdatedAt: Date,
        type: Model.Type,
        create: () -> Model,
        predicate: (Model) -> Bool,
    ) -> Model? {
        // SwiftData's #Predicate macro can't cleanly compare UUID equality
        // in a generic context, so we fetch-all-then-filter. Volume is at
        // most a few thousand rows; the perf hit is fine.
        let all = (try? modelContext.fetch(FetchDescriptor<Model>())) ?? []
        if let existing = all.first(where: predicate) {
            if existing.updatedAt >= remoteUpdatedAt {
                return nil // Local is newer, skip merge.
            }
            return existing
        }
        let fresh = create()
        modelContext.insert(fresh)
        return fresh
    }

    private func applySessions(_ dtos: [WorkoutSessionDTO]) {
        for dto in dtos {
            guard let session = upsertLocal(
                id: dto.id,
                remoteUpdatedAt: dto.updatedAt,
                type: WorkoutSession.self,
                create: {
                    let s = WorkoutSession(
                        startTime: dto.startTime,
                        isCompleted: dto.isCompleted,
                    )
                    s.id = dto.id
                    return s
                },
                predicate: { $0.id == dto.id },
            ) else { continue }

            session.startTime = dto.startTime
            session.endTime = dto.endTime
            session.isCompleted = dto.isCompleted
            session.startedFromTemplateID = dto.startedFromTemplateID
            session.updatedAt = dto.updatedAt
            session.deletedAt = dto.deletedAt
            session.needsSync = false // just received from server
        }
    }

    private func applyExercises(_ dtos: [ExerciseEntryDTO]) {
        let sessions = (try? modelContext.fetch(FetchDescriptor<WorkoutSession>())) ?? []
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        for dto in dtos {
            guard let entry = upsertLocal(
                id: dto.id,
                remoteUpdatedAt: dto.updatedAt,
                type: ExerciseEntry.self,
                create: {
                    let e = ExerciseEntry(
                        name: dto.name,
                        category: dto.category,
                        order: dto.order,
                    )
                    e.id = dto.id
                    return e
                },
                predicate: { $0.id == dto.id },
            ) else { continue }

            entry.name = dto.name
            entry.category = dto.category
            entry.order = dto.order
            entry.updatedAt = dto.updatedAt
            entry.deletedAt = dto.deletedAt
            entry.needsSync = false
            entry.session = dto.sessionID.flatMap { sessionsByID[$0] }
        }
    }

    private func applySets(_ dtos: [WorkoutSetDTO]) {
        let exercises = (try? modelContext.fetch(FetchDescriptor<ExerciseEntry>())) ?? []
        let exercisesByID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

        for dto in dtos {
            guard let set = upsertLocal(
                id: dto.id,
                remoteUpdatedAt: dto.updatedAt,
                type: WorkoutSet.self,
                create: {
                    let s = WorkoutSet(
                        weight: dto.weight,
                        reps: dto.reps,
                        order: dto.order,
                    )
                    s.id = dto.id
                    return s
                },
                predicate: { $0.id == dto.id },
            ) else { continue }

            set.weight = dto.weight
            set.reps = dto.reps
            set.order = dto.order
            set.updatedAt = dto.updatedAt
            set.deletedAt = dto.deletedAt
            set.needsSync = false
            set.exercise = dto.exerciseID.flatMap { exercisesByID[$0] }
        }
    }

    private func applyTemplates(_ dtos: [WorkoutTemplateDTO]) {
        for dto in dtos {
            guard let template = upsertLocal(
                id: dto.id,
                remoteUpdatedAt: dto.updatedAt,
                type: WorkoutTemplate.self,
                create: {
                    let t = WorkoutTemplate(name: dto.name, order: dto.order)
                    t.id = dto.id
                    return t
                },
                predicate: { $0.id == dto.id },
            ) else { continue }

            template.name = dto.name
            template.order = dto.order
            template.updatedAt = dto.updatedAt
            template.deletedAt = dto.deletedAt
            template.needsSync = false
        }
    }

    private func applyTemplateExercises(_ dtos: [TemplateExerciseDTO]) {
        let templates = (try? modelContext.fetch(FetchDescriptor<WorkoutTemplate>())) ?? []
        let templatesByID = Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })

        for dto in dtos {
            guard let entry = upsertLocal(
                id: dto.id,
                remoteUpdatedAt: dto.updatedAt,
                type: TemplateExercise.self,
                create: {
                    let e = TemplateExercise(
                        name: dto.name,
                        category: dto.category,
                        order: dto.order,
                    )
                    e.id = dto.id
                    return e
                },
                predicate: { $0.id == dto.id },
            ) else { continue }

            entry.name = dto.name
            entry.category = dto.category
            entry.order = dto.order
            entry.updatedAt = dto.updatedAt
            entry.deletedAt = dto.deletedAt
            entry.needsSync = false
            entry.template = dto.templateID.flatMap { templatesByID[$0] }
        }
    }

    /// Reconcile the singleton user profile. Always one row locally;
    /// we fetch it by `UserProfile.singletonID` (not by generic upsert)
    /// since the server payload carries no id field.
    private func applyProfile(_ dto: UserProfileDTO) {
        let descriptor = FetchDescriptor<UserProfile>()
        let existing = (try? modelContext.fetch(descriptor))?.first

        let profile: UserProfile
        if let existing {
            // Client-side LWW: server delta wins only if strictly newer
            // than our copy. Matches the server's UPDATE predicate.
            if existing.updatedAt >= dto.updatedAt { return }
            profile = existing
        } else {
            profile = UserProfile()
            modelContext.insert(profile)
        }

        profile.birthYear = dto.birthYear
        profile.sex = dto.sex
        profile.heightCm = dto.heightCm
        profile.experienceLevel = dto.experienceLevel
        profile.trainingDaysPerWeek = dto.trainingDaysPerWeek
        profile.primaryGoal = dto.primaryGoal
        profile.equipmentAccess = dto.equipmentAccess
        profile.preferredUnit = dto.preferredUnit
        profile.notes = dto.notes
        profile.updatedAt = dto.updatedAt
        profile.deletedAt = dto.deletedAt
        profile.needsSync = false
    }

    private func applyBodyWeightEntries(_ dtos: [BodyWeightEntryDTO]) {
        for dto in dtos {
            guard let entry = upsertLocal(
                id: dto.id,
                remoteUpdatedAt: dto.updatedAt,
                type: BodyWeightEntry.self,
                create: {
                    let e = BodyWeightEntry(
                        weightKg: dto.weightKg,
                        measuredAt: dto.measuredAt,
                        notes: dto.notes,
                    )
                    e.id = dto.id
                    return e
                },
                predicate: { $0.id == dto.id },
            ) else { continue }

            entry.weightKg = dto.weightKg
            entry.measuredAt = dto.measuredAt
            entry.notes = dto.notes
            entry.updatedAt = dto.updatedAt
            entry.deletedAt = dto.deletedAt
            entry.needsSync = false
        }
    }
}
