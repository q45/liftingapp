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
    let onLog: (Double, Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private var orderedSets: [WorkoutSet] { exercise.orderedSets }
    private var lastSet: WorkoutSet? { orderedSets.last }
    private var isKg: Bool { unit == "kg" }
    private var bigStep: Double { isKg ? 5.0 : 5.0 }
    private var smallStep: Double { isKg ? 1.25 : 2.5 }

    @State private var weight: Double = 135
    @State private var reps: Int = 8

    // Text buffers backing the editable TextFields. We keep them as
    // strings (rather than binding a NumberFormatter) so partial input
    // -- "142." on the way to "142.5" -- doesn't get rewritten or
    // rejected mid-keystroke.
    @State private var weightText: String = ""
    @State private var repsText: String = ""

    /// Whether the calculator sheet is visible. The calculator is a
    /// nested sheet so users can do quick arithmetic ("45+25+10+5?")
    /// without losing the set-logger state behind it.
    @State private var showCalculator: Bool = false

    @FocusState private var focusedField: Field?
    private enum Field { case weight, reps }

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
                        Text("Set \(orderedSets.count + 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.appMuted)
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
                        Text("\(formatWeight(last.weight)) \(unit) × \(last.reps) reps")
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
                    .padding(.bottom, 20)
                }

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

                // Reps
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
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

                // Log button
                Button("Log — \(formatWeight(weight)) \(unit) × \(reps) reps") {
                    commitWeight()
                    commitReps()
                    onLog(weight, reps)
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .toolbar {
            // Keyboard accessory: "Done" dismisses the numeric keyboard
            // (numberPad / decimalPad have no return key of their own).
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    commitWeight()
                    commitReps()
                    focusedField = nil
                }
                .foregroundColor(.appAccent)
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            if let last = lastSet {
                weight = last.weight
                reps = last.reps
            } else {
                weight = isKg ? 60 : 135
                reps = 8
            }
            weightText = formatWeight(weight)
            repsText = "\(reps)"
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

    // MARK: - Formatting helpers

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
