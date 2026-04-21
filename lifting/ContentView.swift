// ContentView.swift
// Root tab navigation. Instantiates WorkoutManager lazily with the
// shared SwiftData context so the active workout is persisted across
// launches (and recovered automatically on restart if the app was
// killed mid-session).

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var workoutManager: WorkoutManager?
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if let manager = workoutManager {
                TabView(selection: $selectedTab) {
                    HomeView(selectedTab: $selectedTab)
                        .tabItem { Label("Home", systemImage: "house.fill") }
                        .tag(0)

                    WorkoutView()
                        .tabItem { Label("Workout", systemImage: "dumbbell.fill") }
                        .tag(1)
                        .badge(manager.isActive ? "●" : nil)

                    HistoryView()
                        .tabItem { Label("History", systemImage: "waveform.path.ecg") }
                        .tag(2)

                    CoachView()
                        .tabItem { Label("AI Coach", systemImage: "sparkles") }
                        .tag(3)
                }
                .tint(.appAccent)
                .environment(manager)
                .preferredColorScheme(.dark)
            } else {
                // One-frame placeholder while the manager is being
                // created. SwiftUI's `.task` + `@State` can't be used
                // to build a @MainActor type during property init, so
                // we construct it on appearance here.
                Color.appBg.ignoresSafeArea()
                    .task { workoutManager = WorkoutManager(modelContext: modelContext) }
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [WorkoutSession.self, ExerciseEntry.self, WorkoutSet.self], inMemory: true)
}
