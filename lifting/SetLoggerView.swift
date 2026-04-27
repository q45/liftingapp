// SetLoggerView.swift
// Bottom sheet for logging a single set -- weight and reps with +/- controls.
//
// The big number readouts are also editable TextFields. Tap either to
// bring up the numeric keyboard; +/- buttons mutate the same underlying
// value, so the two inputs stay in sync. The display uses
// `.minimumScaleFactor(0.5)` + `.lineLimit(1)` so values with a decimal
// (e.g. `142.5`) scale down to one line instead of wrapping.

import SwiftUI

struct SetLoggerView: View {
    let exercise: ExerciseEntry
    let unit: String
    /// When non-nil, the sheet is in "edit this set" mode: fields
    /// pre-populate from the existing values, the CTA reads "Save
    /// Changes" instead of "Log — …", and a destructive Delete Set
    /// button appears below. When nil, the sheet creates a new set.
    let editing: WorkoutSet?
    /// Called with (weight, reps, durationSeconds) when the user
    /// confirms. `durationSeconds` is non-nil for timed sets (plank,
    /// dead hang) and nil for rep-based sets (the legacy default).
    /// In edit mode this is an update; in log mode it's an append.
    /// The parent forwards to `WorkoutManager.addSet` / `.updateSet`.
    let onLog: (Double, Int, Int?) -> Void
    /// Only invoked when editing -- taps the Delete Set button.
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private var orderedSets: [WorkoutSet] { exercise.orderedSets }
    private var lastSet: WorkoutSet? { orderedSets.last }
    private var isKg: Bool { unit == "kg" }
    private var bigStep: Double { isKg ? 5.0 : 5.0 }
    private var smallStep: Double { isKg ? 1.25 : 2.5 }

    /// 1-indexed position of the set being edited, for the sheet title
    /// ("Edit Set 3"). Falls back to 0 if the set isn't found, which
    /// should be impossible when editing but keeps the optional chain
    /// tidy.
    private var editingSetNumber: Int {
        guard let editing else { return 0 }
        return (orderedSets.firstIndex(where: { $0.id == editing.id }) ?? 0) + 1
    }

    /// True in edit mode. Cleaner read than checking `editing != nil`
    /// every time in the view body.
    private var isEditing: Bool { editing != nil }

    @State private var weight: Double = 135
    @State private var reps: Int = 8
    /// Working seconds for time-mode sets. Persisted into the set's
    /// `durationSeconds` only when `setKind == .time`. Kept separate
    /// from `reps` so a user can flip between modes without losing
    /// either value.
    @State private var seconds: Int = 30

    /// Tracks which input mode the sheet is in. `setKind` is the
    /// source of truth; the views read it and the commit path uses
    /// it to decide what to write.
    @State private var setKind: SetKind = .reps

    private enum SetKind: String, CaseIterable, Identifiable {
        case reps, time
        var id: String { rawValue }
        var label: String { self == .reps ? "Reps" : "Time" }
    }

    // Text buffers backing the editable TextFields. We keep them as
    // strings (rather than binding a NumberFormatter) so partial input
    // -- "142." on the way to "142.5" -- doesn't get rewritten or
    // rejected mid-keystroke.
    @State private var weightText: String = ""
    @State private var repsText: String = ""
    /// Display buffer for the time field, formatted as "m:ss" or
    /// "h:mm:ss". Free-edit + commit on blur, same pattern as the
    /// weight/reps fields.
    @State private var secondsText: String = ""

    /// Whether the calculator sheet is visible. The calculator is a
    /// nested sheet so users can do quick arithmetic ("45+25+10+5?")
    /// without losing the set-logger state behind it.
    @State private var showCalculator: Bool = false

    /// Guards the "confirm delete" alert in edit mode. Deleting a
    /// logged set is destructive; one tap to open the alert, one to
    /// confirm. Three intentional taps between the user and an
    /// irreversible change feels right when they came here to *edit*,
    /// not nuke.
    @State private var showDeleteConfirm: Bool = false

    @FocusState private var focusedField: Field?
    private enum Field { case weight, reps, seconds }

    // MARK: - Initializers
    //
    // Two overloads so existing callers that only log new sets don't
    // have to pass `editing: nil, onDelete: nil` literally. The edit
    // init requires both the existing set and an onDelete handler so
    // the struct's invariants ("edit mode always has delete")
    // enforce at compile time.

    /// New-set initializer. Used by the "Log Set" button in the
    /// ExerciseCard and the AI coach sheet.
    init(
        exercise: ExerciseEntry,
        unit: String,
        onLog: @escaping (Double, Int, Int?) -> Void,
    ) {
        self.exercise = exercise
        self.unit = unit
        self.editing = nil
        self.onLog = onLog
        self.onDelete = nil
    }

    /// Edit-set initializer. Used when the user taps an already-logged
    /// set to correct a typo.
    init(
        exercise: ExerciseEntry,
        unit: String,
        editing: WorkoutSet,
        onSave: @escaping (Double, Int, Int?) -> Void,
        onDelete: @escaping () -> Void,
    ) {
        self.exercise = exercise
        self.unit = unit
        self.editing = editing
        self.onLog = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        ZStack {
            Color(red: 0.086, green: 0.086, blue: 0.086).ignoresSafeArea()
            VStack(spacing: 0) {
                // Handle
                Capsule()
                    .fill(Color.appBorder)
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                // Title
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isEditing ? "EDIT SET \(editingSetNumber)" : "SET \(orderedSets.count + 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isEditing ? .appAccent : .appMuted)
                            .kerning(1)
                        Text(exercise.name)
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
                .padding(.bottom, 16)

                // Previous set reference
                if let last = lastSet {
                    HStack {
                        Text("Previous: ")
                            .foregroundColor(.appMuted)
                        Text(previousSummary(for: last))
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                // Reps / Time picker. Sits above the inputs so the
                // user sees the choice before entering values; toggling
                // doesn't lose either side's typed value (reps + seconds
                // live in separate @State).
                Picker("", selection: $setKind) {
                    ForEach(SetKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .accessibilityLabel("Set type")

                // Weight
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("WEIGHT (\(unit))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.appMuted)
                            .kerning(0.8)
                        Spacer()
                        // Inline calculator. Kept small and adjacent to
                        // the weight label so it's discoverable without
                        // competing with the primary adjust controls
                        // below. Tapping pre-fills the calculator with
                        // the current weight (via commitWeight()) so
                        // users can tweak rather than retype.
                        Button {
                            commitWeight()
                            focusedField = nil
                            showCalculator = true
                        } label: {
                            Label("Calc", systemImage: "function")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.appAccent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.appAccent.opacity(0.12))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(Color.appAccent.opacity(0.3), lineWidth: 1),
                                )
                        }
                        .accessibilityLabel("Open calculator")
                    }
                    HStack(spacing: 10) {
                        AdjButton(label: "−\(stepLabel(bigStep))") { adjustWeight(-bigStep) }
                        AdjButton(label: "−\(stepLabel(smallStep))", small: true) { adjustWeight(-smallStep) }
                        EditableNumberField(
                            text: $weightText,
                            keyboard: .decimalPad,
                            onCommit: commitWeight,
                        )
                        .focused($focusedField, equals: .weight)
                        AdjButton(label: "+\(stepLabel(smallStep))", small: true) { adjustWeight(smallStep) }
                        AdjButton(label: "+\(stepLabel(bigStep))") { adjustWeight(bigStep) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                // Reps OR Time, driven by the segmented picker above.
                // Both have the same +/- AdjButton + EditableNumberField
                // pattern as Weight so the visual rhythm stays
                // consistent. Reps mode is the default; switching modes
                // doesn't clear the other field's @State.
                Group {
                    if setKind == .reps {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("REPS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.appMuted)
                                .kerning(0.8)
                            HStack(spacing: 10) {
                                AdjButton(label: "−1") { adjustReps(-1) }
                                EditableNumberField(
                                    text: $repsText,
                                    keyboard: .numberPad,
                                    onCommit: commitReps,
                                )
                                .focused($focusedField, equals: .reps)
                                AdjButton(label: "+1") { adjustReps(1) }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TIME")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.appMuted)
                                .kerning(0.8)
                            HStack(spacing: 10) {
                                AdjButton(label: "−10") { adjustSeconds(-10) }
                                AdjButton(label: "−5", small: true) { adjustSeconds(-5) }
                                EditableNumberField(
                                    // Time field accepts free-form
                                    // "m:ss" or "h:mm:ss" entry; commit
                                    // handler parses it back into
                                    // seconds. Numeric keypad would
                                    // disallow ":" so we leave it as
                                    // .numbersAndPunctuation.
                                    text: $secondsText,
                                    keyboard: .numbersAndPunctuation,
                                    onCommit: commitSeconds,
                                )
                                .focused($focusedField, equals: .seconds)
                                AdjButton(label: "+5", small: true) { adjustSeconds(5) }
                                AdjButton(label: "+10") { adjustSeconds(10) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

                // Log / Save button
                Button(primaryButtonLabel) {
                    commitWeight()
                    commitReps()
                    commitSeconds()
                    // Time mode passes durationSeconds and reps=0
                    // (parent's WorkoutManager treats reps=0 +
                    // durationSeconds=N as a pure timed set). Reps
                    // mode passes nil for duration, matching the
                    // existing rep-based set semantics.
                    switch setKind {
                    case .reps:
                        onLog(weight, reps, nil)
                    case .time:
                        onLog(weight, 0, max(1, seconds))
                    }
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, isEditing ? 10 : 16)

                // Delete button -- edit mode only. Confirmation alert
                // sits behind $showDeleteConfirm so a misfire doesn't
                // nuke a set the user wanted to keep.
                if isEditing, onDelete != nil {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Set", systemImage: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .foregroundColor(.appRed)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
        }
        .alert("Delete this set?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone from here. The delete still propagates to the server.")
        }
        .toolbar {
            // Keyboard accessory: "Done" dismisses the numeric keyboard
            // (numberPad / decimalPad have no return key of their own).
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    commitWeight()
                    commitReps()
                    commitSeconds()
                    focusedField = nil
                }
                .foregroundColor(.appAccent)
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            // Edit mode: seed from the set being edited; default the
            // mode to whatever this set is. New-set mode: copy from
            // the previous set in this exercise (most natural) and
            // inherit its kind so the second plank set doesn't ask
            // again. Cold start gets sensible defaults.
            if let editing {
                weight = editing.weight
                reps = max(1, editing.reps)
                if let d = editing.durationSeconds, d > 0 {
                    seconds = d
                    setKind = .time
                } else {
                    setKind = .reps
                }
            } else if let last = lastSet {
                weight = last.weight
                if let d = last.durationSeconds, d > 0 {
                    seconds = d
                    reps = 8 // sensible reps fallback if user toggles back
                    setKind = .time
                } else {
                    reps = last.reps
                    seconds = 30
                    setKind = .reps
                }
            } else {
                weight = isKg ? 60 : 135
                reps = 8
                seconds = 30
                setKind = .reps
            }
            weightText = formatWeight(weight)
            repsText = "\(reps)"
            secondsText = formatSeconds(seconds)
        }
        .sheet(isPresented: $showCalculator) {
            CalculatorView(initialValue: weight) { result in
                // Round the calculator result to a plate-sensible
                // increment so "45 / 2 = 22.5" lands exactly where a
                // lifter expects rather than 22.500000001.
                let rounded = (result * 100).rounded() / 100
                weight = max(0, rounded)
                weightText = formatWeight(weight)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }

    // MARK: - Mutation

    private func adjustWeight(_ delta: Double) {
        commitWeight() // flush any in-progress typing first
        weight = max(0, weight + delta)
        weightText = formatWeight(weight)
    }

    private func adjustReps(_ delta: Int) {
        commitReps()
        reps = max(1, reps + delta)
        repsText = "\(reps)"
    }

    private func adjustSeconds(_ delta: Int) {
        commitSeconds()
        seconds = max(1, seconds + delta)
        secondsText = formatSeconds(seconds)
    }

    /// Parse the editable buffer into `weight`. Empty or unparseable
    /// input reverts the buffer to the last known good value so the
    /// field is never left in a broken state.
    private func commitWeight() {
        let trimmed = weightText.trimmingCharacters(in: .whitespaces)
        if let v = Double(trimmed), v >= 0 {
            weight = v
            weightText = formatWeight(v)
        } else {
            weightText = formatWeight(weight)
        }
    }

    private func commitReps() {
        let trimmed = repsText.trimmingCharacters(in: .whitespaces)
        if let v = Int(trimmed), v >= 1 {
            reps = v
            repsText = "\(v)"
        } else {
            repsText = "\(reps)"
        }
    }

    /// Parse the time buffer into `seconds`. Accepts:
    ///   - Bare integers as seconds: "45"        -> 45 s
    ///   - "m:ss":                   "1:30"      -> 90 s
    ///   - "h:mm:ss":                "1:05:00"   -> 3900 s
    /// Anything unparseable reverts the buffer to the last good value
    /// so the field is never left in a broken state. Capped at 24h
    /// (86_400 s) to match the server-side Zod validator.
    private func commitSeconds() {
        let trimmed = secondsText.trimmingCharacters(in: .whitespaces)
        if let parsed = parseDurationString(trimmed), parsed >= 1 {
            seconds = min(86_400, parsed)
            secondsText = formatSeconds(seconds)
        } else {
            secondsText = formatSeconds(seconds)
        }
    }

    private func parseDurationString(_ s: String) -> Int? {
        if s.isEmpty { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return Int(parts[0])
        case 2:
            guard let m = Int(parts[0]), let sec = Int(parts[1]),
                  m >= 0, sec >= 0, sec < 60 else { return nil }
            return m * 60 + sec
        case 3:
            guard let h = Int(parts[0]), let m = Int(parts[1]), let sec = Int(parts[2]),
                  h >= 0, m >= 0, m < 60, sec >= 0, sec < 60 else { return nil }
            return h * 3600 + m * 60 + sec
        default:
            return nil
        }
    }

    // MARK: - Formatting helpers

    /// Primary CTA label. Edit mode reads as a save action because the
    /// user came here to fix something; new-set mode previews the
    /// exact values about to be logged so the user can double-check
    /// before committing. Time mode shows duration instead of reps.
    private var primaryButtonLabel: String {
        if isEditing { return "Save Changes" }
        switch setKind {
        case .reps:
            return "Log — \(formatWeight(weight)) \(unit) × \(reps) reps"
        case .time:
            return "Log — \(formatWeight(weight)) \(unit) × \(formatSeconds(seconds))"
        }
    }

    /// "Previous" summary above the inputs. Adapts to whether the
    /// last set was rep-based or timed so the hint matches reality.
    private func previousSummary(for last: WorkoutSet) -> String {
        if let d = last.durationSeconds, d > 0 {
            return "\(formatWeight(last.weight)) \(unit) × \(formatSeconds(d))"
        }
        return "\(formatWeight(last.weight)) \(unit) × \(last.reps) reps"
    }

    /// Format seconds as "m:ss" up to an hour, "h:mm:ss" beyond.
    /// Handful of rules so 30s reads as "0:30" not "30" (matches the
    /// stopwatch convention users are used to from iOS Workout / Music).
    private func formatSeconds(_ total: Int) -> String {
        let s = max(0, total)
        if s < 3600 {
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%d:%02d:%02d", h, m, sec)
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(w))"
            : String(format: "%.1f", w)
    }

    private func stepLabel(_ step: Double) -> String {
        step.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(step))" : String(format: "%.2g", step)
    }
}

// MARK: - Editable big-number TextField

/// TextField styled to match the bold display numbers. Auto-selects all
/// text when focused so tapping a value lets the user type a replacement
/// immediately.
private struct EditableNumberField: View {
    @Binding var text: String
    let keyboard: UIKeyboardType
    let onCommit: () -> Void

    var body: some View {
        TextField("", text: $text)
            .keyboardType(keyboard)
            .multilineTextAlignment(.center)
            .font(.system(size: 42, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .tint(.appAccent)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .onSubmit { onCommit() }
    }
}

struct AdjButton: View {
    let label: String
    var small: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: small ? 12 : 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: small ? 50 : 58, height: small ? 50 : 58)
                .background(Color.appCard2)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
        }
    }
}
