// CalculatorView.swift
// Generic calculator presented as a sheet from SetLoggerView's weight
// field. The goal isn't to replace iOS's Calculator.app -- it's to keep
// the user in-app when they're doing quick arithmetic mid-workout
// ("what's 45 + 25 + 10 + 5?" or "225 / 2 = how much per side?").
// Swiping to Control Center works, but with sweaty hands mid-set it's
// friction we don't need to impose.
//
// # Design
//
// Standard immediate-execution calculator (like iOS's default): no
// operator precedence, no parentheses. Each operator press commits any
// pending operation, so `45 + 25 + 10` evaluates left-to-right as you
// type it rather than waiting for =.
//
// The "Use" CTA hands the current display value back to the caller via
// the `onUse` closure. If the display is invalid (empty, error, negative
// when we require non-negative), Use is disabled rather than bouncing
// the user with an alert.

import SwiftUI

struct CalculatorView: View {
    /// Pre-fill the display with this value on first appearance. Pass
    /// the weight field's current value so tapping Calculator doesn't
    /// lose in-progress entry.
    let initialValue: Double?
    /// Called with the current display value when the user taps "Use".
    /// The sheet dismisses itself on behalf of the caller; the closure
    /// is just responsible for applying the number to wherever it goes.
    let onUse: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    // Display model: `display` is what's shown to the user. `accumulator`
    // holds the left operand once an operator is pressed; `pendingOp`
    // is the operation to apply on the next =/operator press.
    //
    // `justEvaluated` lets us distinguish the moment after `=`: typing
    // a new digit should clear the display and start a fresh entry
    // rather than appending to the result.
    @State private var display: String = "0"
    @State private var accumulator: Double? = nil
    @State private var pendingOp: Operation? = nil
    @State private var justEvaluated: Bool = false
    @State private var hasError: Bool = false

    // MARK: - Layout constants

    /// Calculator key spacing matches the app's general 10pt rhythm so
    /// buttons feel consistent with AdjButton in SetLoggerView.
    private let keySpacing: CGFloat = 10

    var body: some View {
        ZStack {
            Color(red: 0.086, green: 0.086, blue: 0.086).ignoresSafeArea()
            VStack(spacing: 0) {
                dragHandle
                titleBar
                displayArea
                keypad
                useButton
            }
        }
        .onAppear(perform: loadInitialValue)
        // Large-only: a full calculator keypad + display + Use button
        // doesn't fit under the .medium fold (around 420pt on a standard
        // iPhone) -- the bottom row including `=` would be clipped, which
        // made early testing feel "buggy" because the equals key wasn't
        // visible without dragging.
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var dragHandle: some View {
        Capsule()
            .fill(Color.appBorder)
            .frame(width: 36, height: 4)
            .padding(.top, 12)
            .padding(.bottom, 14)
    }

    @ViewBuilder
    private var titleBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CALCULATOR")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appMuted)
                    .kerning(1)
                Text("Quick math")
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
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var displayArea: some View {
        // Right-align the big number so digits grow leftward like a
        // hardware calculator. minimumScaleFactor shrinks long values
        // (e.g. 1234567.89) rather than wrapping to a second line.
        HStack {
            Spacer()
            Text(hasError ? "Error" : display)
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .foregroundColor(hasError ? .appRed : .white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var keypad: some View {
        // SwiftUI's Grid gives us real column alignment -- every cell in
        // a column is exactly the same width regardless of its content,
        // unlike HStack + layoutPriority which only distributes *extra*
        // space. That matters here because the bottom row has a
        // column-spanning 0 key, and without Grid the other keys drift
        // out of alignment with the rows above.
        Grid(horizontalSpacing: keySpacing, verticalSpacing: keySpacing) {
            GridRow {
                functionKey(label: clearLabel, action: clearOrAllClear)
                functionKey(label: "±", action: toggleSign)
                functionKey(label: "%", action: percent)
                operatorKey(.divide)
            }
            GridRow {
                digitKey("7"); digitKey("8"); digitKey("9")
                operatorKey(.multiply)
            }
            GridRow {
                digitKey("4"); digitKey("5"); digitKey("6")
                operatorKey(.subtract)
            }
            GridRow {
                digitKey("1"); digitKey("2"); digitKey("3")
                operatorKey(.add)
            }
            GridRow {
                // 0 spans the two leftmost columns so the "." stays in
                // the third-column slot and "=" in the fourth, keeping
                // them visually under 9 and × from the row above.
                digitKey("0").gridCellColumns(2)
                digitKey(".")
                equalsKey
            }
        }
        .padding(.horizontal, 24)
    }

    /// iOS-style toggle: AC while there's nothing to clear, C after the
    /// user has started typing. Matches how Apple's Calculator behaves.
    private var clearLabel: String {
        (display == "0" && accumulator == nil) ? "AC" : "C"
    }

    @ViewBuilder
    private var useButton: some View {
        Button("Use \(formattedForUse())") {
            guard let value = Double(display) else { return }
            onUse(value)
            dismiss()
        }
        .buttonStyle(AccentButtonStyle())
        .disabled(!canUse)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    // MARK: - Key builders

    @ViewBuilder
    private func digitKey(_ label: String) -> some View {
        CalcKey(label: label, style: .digit) { inputDigit(label) }
    }

    @ViewBuilder
    private func functionKey(label: String, action: @escaping () -> Void) -> some View {
        CalcKey(label: label, style: .function, action: action)
    }

    @ViewBuilder
    private func operatorKey(_ op: Operation) -> some View {
        CalcKey(
            label: op.symbol,
            style: .operation,
            isSelected: pendingOp == op && !justEvaluated,
            action: { pressOperator(op) },
        )
    }

    @ViewBuilder
    private var equalsKey: some View {
        // Force-selected styling so = reads as the "primary" action in
        // the operator column. Without this it's visually identical to
        // the other operator keys, which made users hunt for it.
        CalcKey(label: "=", style: .operation, isSelected: true, action: evaluate)
    }

    // MARK: - Input handlers
    //
    // Kept separate from the view hierarchy so the mutation paths are
    // easy to reason about without hunting through .onTapGesture closures.

    private func loadInitialValue() {
        guard let v = initialValue, v.isFinite else { return }
        display = format(v)
        justEvaluated = true // next digit should start fresh, not append
    }

    private func inputDigit(_ digit: String) {
        hasError = false

        // Prevent multiple decimal points in a single number.
        if digit == "." && display.contains(".") && !justEvaluated {
            return
        }

        if justEvaluated || display == "0" {
            // Start a new number: "." becomes "0." (so 0.5 works); other
            // digits just replace the zero so we don't end up with "07".
            display = (digit == ".") ? "0." : digit
            justEvaluated = false
        } else {
            // Cap at 12 digits so display doesn't blow past minimumScaleFactor.
            guard display.count < 12 else { return }
            display += digit
        }
    }

    private func pressOperator(_ op: Operation) {
        hasError = false

        // If there's a pending op AND the user has typed a second operand
        // since the last =, evaluate before chaining so `45 + 25 * 2`
        // computes as (45+25)*2 = 140 (left-to-right, no precedence --
        // matches iOS's default calculator).
        if let pending = pendingOp, let acc = accumulator, !justEvaluated {
            if let result = apply(pending, lhs: acc, rhs: Double(display) ?? 0) {
                accumulator = result
                display = format(result)
            } else {
                hasError = true
                return
            }
        } else {
            accumulator = Double(display)
        }

        pendingOp = op
        justEvaluated = true // next digit starts fresh
    }

    private func evaluate() {
        guard let op = pendingOp, let lhs = accumulator else { return }
        let rhs = Double(display) ?? 0
        if let result = apply(op, lhs: lhs, rhs: rhs) {
            display = format(result)
            accumulator = nil
            pendingOp = nil
            justEvaluated = true
        } else {
            hasError = true
            accumulator = nil
            pendingOp = nil
        }
    }

    /// AC clears everything; C clears just the current entry. We pick
    /// between them based on whether the user has typed anything since
    /// the last reset -- same heuristic iOS's Calculator uses.
    private func clearOrAllClear() {
        if display != "0" && !justEvaluated {
            display = "0"
        } else {
            display = "0"
            accumulator = nil
            pendingOp = nil
            justEvaluated = false
            hasError = false
        }
    }

    private func toggleSign() {
        hasError = false
        guard let v = Double(display) else { return }
        display = format(-v)
    }

    private func percent() {
        hasError = false
        guard let v = Double(display) else { return }
        display = format(v / 100)
    }

    // MARK: - Evaluation

    private func apply(_ op: Operation, lhs: Double, rhs: Double) -> Double? {
        switch op {
        case .add:      return lhs + rhs
        case .subtract: return lhs - rhs
        case .multiply: return lhs * rhs
        case .divide:
            guard rhs != 0 else { return nil } // surfaces as "Error"
            return lhs / rhs
        }
    }

    // MARK: - Formatting

    /// Format a Double for display: no trailing zeros, max 6 decimals
    /// so `1/3 = 0.333333` fits in the 12-char cap.
    private func format(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return "Error" }
        if value.truncatingRemainder(dividingBy: 1) == 0,
           abs(value) < 1e12 {
            return String(Int(value))
        }
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Variant for the Use button label: rounds to 2 decimal places
    /// so weight values read as 142.5 not 142.50000.
    private func formattedForUse() -> String {
        guard let v = Double(display), v.isFinite else { return "—" }
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(v))"
        }
        return String(format: "%.2f", v)
    }

    private var canUse: Bool {
        guard !hasError, let v = Double(display), v.isFinite else { return false }
        return v >= 0
    }
}

// MARK: - Operation enum

private enum Operation: Equatable {
    case add, subtract, multiply, divide

    var symbol: String {
        switch self {
        case .add:      return "+"
        case .subtract: return "−"  // U+2212 minus sign (wider than hyphen)
        case .multiply: return "×"
        case .divide:   return "÷"
        }
    }
}

// MARK: - CalcKey

/// Individual calculator button. Three visual styles (digit, operator,
/// function) mirror iOS's stock calculator hierarchy so users read the
/// layout at a glance: operators stand out in accent, functions in a
/// secondary fill, digits plain.
private struct CalcKey: View {
    enum Style { case digit, function, operation }

    let label: String
    let style: Style
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity)
                // 58pt matches AdjButton sizing in SetLoggerView and
                // keeps the full 5-row keypad visible within the large
                // detent on compact devices (iPhone SE, Mini).
                .frame(height: 58)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(borderColor, lineWidth: 1),
                )
        }
    }

    private var fill: Color {
        switch style {
        case .digit: return Color.appCard
        case .function: return Color.appCard2
        case .operation: return isSelected ? Color.appAccent : Color.appAccent.opacity(0.15)
        }
    }

    private var textColor: Color {
        switch style {
        case .digit: return .white
        case .function: return .white
        case .operation: return isSelected ? .black : .appAccent
        }
    }

    private var borderColor: Color {
        switch style {
        case .digit, .function: return Color.appBorder
        case .operation: return isSelected ? Color.appAccent : Color.appAccent.opacity(0.3)
        }
    }
}
