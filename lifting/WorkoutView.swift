// WorkoutView.swift
// Active workout screen — exercise list, set logging, finish.
//
// The underlying state lives in SwiftData via WorkoutManager, so mid-
// workout crashes / force-quits don't lose data; the next launch picks
// up where the user left off.

import SwiftUI
import SwiftData

struct WorkoutView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.modelContext) private var context
    @AppStorage("weightUnit") private var unit = "lbs"

    @State private var showPicker = false
    @State private var setTargetID: UUID? = nil
    @State private var coachTargetID: UUID? = nil
    @State private var elapsed: Int = 0
    @State private var timer: Timer? = nil

    /// Template picker sheet trigger (shown from empty state).
    @State private var showTemplatePicker = false

    /// UUID of the just-finished session pending the "save as template?"
    /// prompt. We carry the ID (not the model) because SwiftData @Model
    /// classes can't cleanly conform to Identifiable, which `.sheet(item:)`
    /// requires. The sheet looks the session back up by id on present.
    @State private var pendingFinishedSessionID: UUID? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                if workoutManager.isActive {
                    activeWorkoutBody
                } else {
                    emptyStateBody
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            // Recover the timer when returning to an already-active workout
            // (e.g. after relaunch). Using the session's actual startTime
            // keeps the elapsed counter accurate across cold starts.
            if workoutManager.isActive { startTimer() }
        }
        .onChange(of: workoutManager.isActive) { _, active in
            if active { startTimer() } else { stopTimer() }
        }
        .onDisappear { stopTimer() }
        .sheet(item: Binding(
            get: { pendingFinishedSessionID.map { FinishedSessionTarget(id: $0) } },
            set: { pendingFinishedSessionID = $0?.id },
        )) { target in
            if let session = lookupSession(id: target.id) {
                FinishWorkoutSheet(session: session, unit: unit) { name in
                    // User can tap Save or Skip. On Save we persist a
                    // template off the session's exercise list; on Skip
                    // (nil) we just dismiss. Either way we clear the
                    // state so the sheet doesn't re-present.
                    if let name, !name.isEmpty {
                        workoutManager.createTemplate(from: session, name: name)
                    }
                    pendingFinishedSessionID = nil
                }
            }
        }
    }

    /// Fetch a session by id from SwiftData. Used by the finish sheet
    /// to re-resolve the completed session after WorkoutManager has
    /// already cleared its active pointer.
    private func lookupSession(id: UUID) -> WorkoutSession? {
        let desc = FetchDescriptor<WorkoutSession>()
        let all = (try? context.fetch(desc)) ?? []
        return all.first { $0.id == id }
    }

    // MARK: Empty state
    private var emptyStateBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 44))
                .foregroundColor(.appMuted)
                .padding(20)
                .background(Color.appCard)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            Text("No Active Workout")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
            Text("Start a session to begin logging your lifts")
                .font(.system(size: 14))
                .foregroundColor(.appMuted)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button("Start Blank Workout") { workoutManager.start() }
                    .buttonStyle(AccentButtonStyle())
                // Secondary entry point for reusing a saved template.
                // Styled as SecondaryButtonStyle so the "blank" path
                // remains the visually dominant default -- first-time
                // users with no templates aren't pushed toward an empty
                // picker.
                Button { showTemplatePicker = true } label: {
                    Label("Start from Template", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showTemplatePicker) {
            TemplatePickerSheet(
                onPick: { template in
                    workoutManager.startFromTemplate(template)
                },
                onDelete: { template in
                    workoutManager.deleteTemplate(template)
                },
            )
        }
    }

    // MARK: Active workout
    private var activeWorkoutBody: some View {
        let exercises = workoutManager.exercises
        return VStack(spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Workout")
                        .font(.system(size: 13))
                        .foregroundColor(.appMuted)
                    Text(timerString)
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundColor(.appAccent)
                        .monospacedDigit()
                    Text("\(exercises.count) exercises · \(totalSets(in: exercises)) sets")
                        .font(.system(size: 13))
                        .foregroundColor(.appMuted)
                }
                Spacer()
                Button("Finish") { finishWorkout() }
                    .buttonStyle(AccentButtonStyle())
                    .frame(width: 90)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider().background(Color.appBorder)

            // Exercise list
            ScrollView {
                VStack(spacing: 12) {
                    if exercises.isEmpty {
                        Text("Add your first exercise below")
                            .font(.system(size: 14))
                            .foregroundColor(.appMuted)
                            .padding(.top, 50)
                    }
                    ForEach(exercises, id: \.id) { ex in
                        ExerciseCard(
                            exercise: ex,
                            unit: unit,
                            onAddSet: { setTargetID = ex.id },
                            onAskCoach: { coachTargetID = ex.id },
                            onRemove: { workoutManager.removeExercise(ex) },
                        )
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // Footer
            Divider().background(Color.appBorder)
            Button { showPicker = true } label: {
                Label("Add Exercise", systemImage: "plus")
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showPicker) {
            ExercisePickerView { name, cat in
                workoutManager.addExercise(name: name, category: cat)
                showPicker = false
            }
        }
        .sheet(item: Binding(
            get: { setTargetID.map { SetLoggerTarget(id: $0) } },
            set: { setTargetID = $0?.id },
        )) { target in
            if let ex = workoutManager.exercises.first(where: { $0.id == target.id }) {
                SetLoggerView(exercise: ex, unit: unit) { weight, reps in
                    workoutManager.addSet(to: ex, weight: weight, reps: reps)
                    setTargetID = nil
                }
            }
        }
        .sheet(item: Binding(
            get: { coachTargetID.map { SetLoggerTarget(id: $0) } },
            set: { coachTargetID = $0?.id },
        )) { target in
            if let ex = workoutManager.exercises.first(where: { $0.id == target.id }) {
                ExerciseCoachSheet(
                    exerciseName: ex.name,
                    unit: unit,
                ) { weight, reps in
                    workoutManager.addSet(to: ex, weight: weight, reps: reps)
                    coachTargetID = nil
                }
            }
        }
    }

    private var timerString: String {
        String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private func totalSets(in exercises: [ExerciseEntry]) -> Int {
        exercises.reduce(0) { $0 + $1.liveSets.count }
    }

    private func startTimer() {
        elapsed = Int(Date.now.timeIntervalSince(workoutManager.startTime))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                elapsed = Int(Date.now.timeIntervalSince(workoutManager.startTime))
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func finishWorkout() {
        // Capture the finished session so the FinishWorkoutSheet can
        // summarize it + save as a template. finish() returns nil when
        // the session had no logged sets (it soft-deletes rather than
        // persists an empty record), in which case we skip the sheet.
        let completed = workoutManager.finish()
        stopTimer()
        elapsed = 0
        if let completed {
            pendingFinishedSessionID = completed.id
        }
    }
}

// Identifiable wrapper for the SetLoggerView sheet.
struct SetLoggerTarget: Identifiable {
    let id: UUID
}

// Identifiable wrapper for the FinishWorkoutSheet. We can't bind
// `.sheet(item:)` to a WorkoutSession directly because SwiftData
// @Model's autogenerated conformance collides with a hand-rolled
// Identifiable extension; a tiny UUID wrapper sidesteps that while
// letting us resolve the full session by id in the sheet closure.
struct FinishedSessionTarget: Identifiable {
    let id: UUID
}

// MARK: - Exercise Card

struct ExerciseCard: View {
    let exercise: ExerciseEntry
    let unit: String
    let onAddSet: () -> Void
    let onAskCoach: () -> Void
    let onRemove: () -> Void

    @State private var expanded = true

    private var orderedSets: [WorkoutSet] { exercise.orderedSets }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                Circle()
                    .fill(categoryColor(exercise.category))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text("\(orderedSets.count) set\(orderedSets.count == 1 ? "" : "s")\(exercise.bestWeight > 0 ? " · \(Int(exercise.bestWeight)) \(unit) best" : "")")
                        .font(.system(size: 12))
                        .foregroundColor(.appMuted)
                }
                Spacer()
                // Per-exercise AI coach. Tapping opens a sheet that asks
                // the server for a recommendation based on this exercise's
                // history; the sheet lets the user log a set with the
                // recommended weight/reps in one tap.
                Button { onAskCoach() } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.appAccent)
                }
                .padding(8)
                .accessibilityLabel("AI coach recommendation for \(exercise.name)")

                Button { onRemove() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.appMuted)
                }
                .padding(8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }

            if expanded {
                VStack(spacing: 0) {
                    if !orderedSets.isEmpty {
                        HStack {
                            Text("#").frame(width: 28, alignment: .leading)
                            Text("Weight").frame(maxWidth: .infinity)
                            Text("Reps").frame(maxWidth: .infinity)
                            Text("Vol").frame(width: 44, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.appMuted)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                        Divider().background(Color.appBorder).padding(.horizontal, 16)

                        ForEach(Array(orderedSets.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Text("\(i + 1)")
                                    .frame(width: 28, alignment: .leading)
                                    .foregroundColor(.appMuted)
                                HStack(spacing: 2) {
                                    Text("\(Int(s.weight))")
                                        .fontWeight(.bold)
                                    Text(unit).foregroundColor(.appMuted)
                                }
                                .frame(maxWidth: .infinity)
                                HStack(spacing: 2) {
                                    Text("\(s.reps)").fontWeight(.bold)
                                    Text("reps").foregroundColor(.appMuted)
                                }
                                .frame(maxWidth: .infinity)
                                Text("\(Int(s.weight) * s.reps)")
                                    .frame(width: 44, alignment: .trailing)
                                    .foregroundColor(.appMuted)
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 9)
                            if i < orderedSets.count - 1 {
                                Divider().background(Color.appBorder).padding(.horizontal, 16)
                            }
                        }
                        Divider().background(Color.appBorder).padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    }

                    Button { onAddSet() } label: {
                        Label("Log Set", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }
}

// MARK: - Per-exercise AI coach sheet
//
// Shown when the user taps the sparkles button on an ExerciseCard.
// Calls POST /coach/exercise-recommendation via ClaudeService; while the
// server is thinking we show a spinner (first call is 3-8s, cached calls
// are instant). On success we render the prescription and a single
// "Log Set" CTA that applies it via the same callback SetLoggerView uses,
// so the set is persisted and synced through the existing WorkoutManager
// path.

struct ExerciseCoachSheet: View {
    let exerciseName: String
    let unit: String
    let onLog: (Double, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("userGoal") private var goal = "stronger"

    @State private var outcome: ExerciseCoachOutcome? = nil
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        ZStack {
            Color(red: 0.086, green: 0.086, blue: 0.086).ignoresSafeArea()
            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.appBorder)
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                // Title row
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.appAccent)
                            Text("AI COACH")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.appAccent)
                                .kerning(1)
                        }
                        Text(exerciseName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.appMuted)
                            .padding(10)
                            .background(Color.appCard2)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                ScrollView {
                    VStack(spacing: 14) {
                        if isLoading {
                            loadingBlock
                        } else if let err = errorMessage {
                            errorBlock(err)
                        } else if let outcome {
                            recommendationBlock(outcome)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 24)
                }

                // Primary CTA (enabled once we have a recommendation).
                if let outcome {
                    Button("Log Set — \(formatWeight(outcome.weight)) \(unit) × \(outcome.reps) reps") {
                        onLog(outcome.weight, outcome.reps)
                        dismiss()
                    }
                    .buttonStyle(AccentButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
        }
        .task { await fetch(refresh: false) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var loadingBlock: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.appAccent)
            Text("Claude is analyzing your \(exerciseName.lowercased()) history…")
                .font(.system(size: 13))
                .foregroundColor(.appMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func errorBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.appRed)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.appRed)
            }
            Button {
                Task { await fetch(refresh: true) }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appAccent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appRed.opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder
    private func recommendationBlock(_ outcome: ExerciseCoachOutcome) -> some View {
        // Prescription card (big numbers, at-a-glance).
        HStack(spacing: 0) {
            metricCell(label: "WEIGHT", value: "\(formatWeight(outcome.weight))", sub: unit)
            Divider().background(Color.appBorder).frame(width: 1)
            metricCell(label: "SETS", value: "\(outcome.sets)", sub: nil)
            Divider().background(Color.appBorder).frame(width: 1)
            metricCell(label: "REPS", value: "\(outcome.reps)", sub: nil)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))

        // Rationale — the "why" so the user trusts the number.
        VStack(alignment: .leading, spacing: 6) {
            Text("WHY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.8)
            Text(outcome.rationale)
                .font(.system(size: 14))
                .foregroundColor(.appMuted2)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))

        // Tip (short actionable cue).
        if !outcome.tip.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.appAccent)
                    .padding(.top, 2)
                Text(outcome.tip)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appAccent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appAccent.opacity(0.3), lineWidth: 1))
        }

        // Source badge + regenerate affordance. For offline results we
        // tag the recommendation so the user knows it came from local
        // heuristics (not the LLM), and we offer to retry the server
        // instead of the usual "regenerate" wording.
        HStack {
            sourceBadge(outcome.source)
            Spacer()
            switch outcome.source {
            case .server:
                Button {
                    Task { await fetch(refresh: true) }
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.appAccent)
                }
            case .offline:
                Button {
                    Task { await fetch(refresh: false) }
                } label: {
                    Label("Retry server", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.appAccent)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func sourceBadge(_ source: ExerciseCoachOutcome.Source) -> some View {
        switch source {
        case .server(let cached):
            if cached {
                Label("Cached", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appMuted)
            } else {
                EmptyView()
            }
        case .offline:
            Label("Offline suggestion", systemImage: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appMuted)
        }
    }

    @ViewBuilder
    private func metricCell(label: String, value: String, sub: String?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.8)
            Text(value)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let sub {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundColor(.appMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: - Networking

    /// Try the server first; on any failure (offline, 5xx, Anthropic
    /// outage, missing API key server-side), fall through to the local
    /// rule-based coach so the user still gets a usable number. We
    /// deliberately don't surface the network error in the offline case
    /// -- the UI already communicates "offline suggestion" via the badge,
    /// and a red error banner above a perfectly usable recommendation
    /// would just be noise.
    private func fetch(refresh: Bool) async {
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await ClaudeService.fetchExerciseRecommendation(
                exerciseName: exerciseName,
                goal: goal,
                unit: unit,
                refresh: refresh,
            )
            outcome = ExerciseCoachOutcome(serverResponse: resp)
        } catch {
            print("⚠️ Exercise coach server call failed, falling back to local: \(error)")
            outcome = LocalCoach.recommend(
                exerciseName: exerciseName,
                goal: goal,
                unit: unit,
                context: modelContext,
            )
        }
        isLoading = false
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(w))"
            : String(format: "%.1f", w)
    }
}
