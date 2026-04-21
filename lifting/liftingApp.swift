// liftingApp.swift
// App entry point. Wires:
//   - SwiftData ModelContainer (with self-healing on schema mismatch)
//   - SyncEngine singleton (push/pull against the lifting server)
//   - WorkoutManager (backed by the shared model context)

import SwiftUI
import SwiftData

@main
struct liftingApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            WorkoutSession.self,
            ExerciseEntry.self,
            WorkoutSet.self,
            WorkoutTemplate.self,
            TemplateExercise.self,
            UserProfile.self,
            BodyWeightEntry.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // First attempt: normal path. SwiftData handles lightweight
        // migrations (adding properties with defaults) automatically.
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("⚠️ ModelContainer creation failed (likely schema mismatch): \(error)")

            // Recovery: the on-disk store is incompatible. In dev this
            // is almost always because we added properties and the store
            // was created with an older version. Delete the store and
            // retry so the app at least boots into a clean state.
            // The server is the source of truth; SyncEngine will
            // re-hydrate everything on the next pull.
            if let url = config.url as URL? {
                try? FileManager.default.removeItem(at: url)
                // SwiftData keeps companion files (.store-shm, .store-wal)
                // next to the main store. Clean them up too.
                for suffix in ["-shm", "-wal"] {
                    let sibling = url.appendingPathExtension(
                        suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-")),
                    )
                    try? FileManager.default.removeItem(at: sibling)
                }
                print("🧹 Removed incompatible SwiftData store at \(url.path). Retrying.")
            }

            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Could not create ModelContainer even after reset: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Bootstrap sync on first render. Safe to call more
                    // than once; subsequent calls just trigger a sync.
                    await configureSyncIfNeeded()
                }
                // Dark-only UI. Forcing the color scheme keeps system-
                // provided surfaces (alerts, sheets, pickers) consistent
                // with our custom tokens.
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }

    @MainActor
    private func configureSyncIfNeeded() async {
        guard SyncEngine.shared == nil else {
            await SyncEngine.shared?.syncNow()
            return
        }
        // AuthManager supplies the session JWT (nil when signed out, which
        // is OK -- the server's DEV_BYPASS_AUTH escape hatch lets dev
        // builds continue to sync as the legacy user until Phase 2 ships
        // the Sign in with Apple / Google UI).
        let api = AuthManager.shared.authorizedClient()
        SyncEngine.shared = SyncEngine(
            api: api,
            modelContext: sharedModelContainer.mainContext,
        )
        await SyncEngine.shared?.syncNow()
    }
}
