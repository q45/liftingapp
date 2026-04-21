// HomeView.swift
// Dashboard: stats row, Start Workout CTA, and a list of recent workouts.
//
// Earlier versions of this screen carried a "My Goal" picker and a
// "Weight Unit" toggle. Both moved elsewhere:
//
//   - Goal -> CoachView's own picker, where changing it actually affects
//     what the screen renders (it drives the Claude prompt). A second
//     picker here was a remote control with no local feedback.
//
//   - Unit -> ProfileView's Units picker, which writes through to the
//     @AppStorage("weightUnit") key the rest of the app reads.
//
// The net effect: Home becomes a glanceable dashboard + a launcher.

import SwiftUI
import SwiftData

struct HomeView: View {
    @Binding var selectedTab: Int
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.modelContext) private var context
    @Query(sort: \WorkoutSession.endTime) private var allSessions: [WorkoutSession]

    /// Weight unit for display. Written canonically by ProfileView --
    /// this view only reads it for stat labels + row rendering.
    @AppStorage("weightUnit") private var unit = "lbs"

    /// Completed, non-tombstoned workouts only. Active workouts live
    /// inside WorkoutManager and shouldn't feed history stats.
    private var workouts: [WorkoutSession] {
        allSessions.filter { $0.isLive && $0.isCompleted }
    }

    private var weekWorkouts: [WorkoutSession] {
        let cutoff = Date.now.addingTimeInterval(-7 * 86400)
        return workouts.filter { $0.endTime > cutoff }
    }

    private var weekVolume: Double {
        weekWorkouts.reduce(0) { $0 + $1.totalVolume }
    }

    private var streak: Int {
        guard !workouts.isEmpty else { return 0 }
        var count = 0
        var day = Calendar.current.startOfDay(for: .now)
        for w in workouts.reversed() {
            let wDay = Calendar.current.startOfDay(for: w.endTime)
            let diff = Calendar.current.dateComponents([.day], from: wDay, to: day).day ?? 99
            if diff <= 1 { count += 1; day = wDay } else { break }
        }
        return count
    }

    /// Recent workouts for the home list. Capped at 6 to keep the home
    /// dashboard from becoming an infinite scroll -- the History tab is
    /// the right surface for exhaustive review. Sorted newest-first.
    private var recentWorkouts: [WorkoutSession] {
        workouts.sorted(by: { $0.endTime > $1.endTime }).prefix(6).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                                .font(.system(size: 13))
                                .foregroundColor(.appMuted)
                            Text("Ready to lift?")
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)

                        // Stats row
                        HStack(spacing: 10) {
                            StatCard(value: "\(weekWorkouts.count)",
                                     sub: "workouts", label: "This Week")
                            StatCard(value: weekVolume > 0
                                     ? String(format: "%.1fk", weekVolume / 1000) : "—",
                                     sub: unit, label: "Volume")
                            StatCard(value: "\(streak)", sub: "days", label: "Streak")
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)

                        // Start CTA
                        Button("Start Workout") {
                            if !workoutManager.isActive { workoutManager.start() }
                            selectedTab = 1
                        }
                        .buttonStyle(AccentButtonStyle())
                        .padding(.horizontal, 20)
                        .padding(.bottom, 22)

                        // Recent workouts
                        recentWorkoutsSection

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: - Recent workouts

    @ViewBuilder
    private var recentWorkoutsSection: some View {
        if recentWorkouts.isEmpty {
            emptyRecentState
                .padding(.horizontal, 20)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Recent Workouts")
                    Spacer()
                    if workouts.count > recentWorkouts.count {
                        // "View all" shortcut surfaces that History is
                        // where the full log lives.
                        Button {
                            selectedTab = 2
                        } label: {
                            Text("View all")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.appAccent)
                        }
                    }
                }
                .padding(.horizontal, 20)

                VStack(spacing: 8) {
                    ForEach(recentWorkouts, id: \.id) { session in
                        Button {
                            selectedTab = 2
                        } label: {
                            RecentWorkoutRow(session: session, unit: unit)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private var emptyRecentState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No workouts yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text("Tap Start Workout above to log your first session.")
                .font(.system(size: 13))
                .foregroundColor(.appMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }
}

// MARK: - Row

/// Single card in the Recent Workouts list. Shows a compact header
/// (date + duration) on top, a wrapping list of exercise names below,
/// and a metric row at the bottom. Designed to convey what the user
/// actually did in a session at a glance, without needing to drill in.
struct RecentWorkoutRow: View {
    let session: WorkoutSession
    let unit: String

    private var exerciseNames: String {
        let names = session.orderedExercises.map(\.name)
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " +\(names.count - 3)"
    }

    private var volumeLabel: String {
        let v = session.totalVolume
        if v == 0 { return "—" }
        if v >= 1000 {
            return String(format: "%.1fk %@", v / 1000, unit)
        }
        return "\(Int(v)) \(unit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(session.endTime.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(session.durationString)
                    .font(.system(size: 12))
                    .foregroundColor(.appMuted)
                    .monospacedDigit()
            }

            if !exerciseNames.isEmpty {
                Text(exerciseNames)
                    .font(.system(size: 13))
                    .foregroundColor(.appMuted2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 14) {
                metric(value: "\(session.orderedExercises.count)", label: "ex")
                divider
                metric(value: "\(session.totalSets)", label: "sets")
                divider
                metric(value: volumeLabel, label: "vol")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func metric(value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.appMuted)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.appBorder)
            .frame(width: 1, height: 10)
    }
}
