// ExerciseProgressView.swift
// Per-exercise drilldown: max-weight chart + per-session breakdown.
//
// Reached from:
//   - HistoryView's Personal Records list (tap a PR row).
//   - HistoryView's Exercise Progress cards (tap a card).
//
// The screen is single-exercise by design. To browse a different
// exercise the user backs out and taps another one. That's a
// deliberate UX choice -- the older "horizontal chip picker at the
// top of History" forced users to make a choice before they could
// see anything, which was the main complaint about the old History
// tab. Splitting the chooser (HistoryView) from the viewer (this
// file) gives each its own focused job.

import SwiftUI
import SwiftData
import Charts

struct ExerciseProgressView: View {
    /// Case-sensitive exact match. Sessions are filtered to those
    /// containing an exercise with this name.
    let exerciseName: String

    @Query(sort: \WorkoutSession.endTime) private var allSessions: [WorkoutSession]
    @AppStorage("weightUnit") private var unit = "lbs"

    private var workouts: [WorkoutSession] {
        allSessions.filter { $0.isLive && $0.isCompleted }
    }

    /// One point per session that contained this exercise. Used both
    /// for the chart and the session-by-session breakdown below.
    private var chartData: [ChartPoint] {
        let relevant = workouts.filter { w in
            w.liveExercises.contains { $0.name == exerciseName }
        }
        return relevant.enumerated().compactMap { i, w in
            guard let ex = w.liveExercises.first(where: { $0.name == exerciseName }),
                  !ex.liveSets.isEmpty else { return nil }
            return ChartPoint(
                session: i + 1,
                maxWeight: ex.orderedSets.map(\.weight).max() ?? 0,
                date: w.endTime,
                sets: ex.orderedSets,
                workoutSession: w,
            )
        }
    }

    /// All-time best top set across history. Heaviest weight, ties
    /// broken by reps -- same rule used elsewhere in the app.
    private var topSet: WorkoutSet? {
        let allSets = workouts
            .flatMap { $0.liveExercises }
            .filter { $0.name == exerciseName }
            .flatMap(\.liveSets)
        return allSets.max { a, b in
            a.weight < b.weight || (a.weight == b.weight && a.reps < b.reps)
        }
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            if chartData.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(exerciseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let top = topSet {
                    prHeader(top: top)
                        .padding(.horizontal, 20)
                }

                chartCard
                    .padding(.horizontal, 20)

                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appMuted)
                    .kerning(0.8)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                ForEach(chartData.reversed()) { point in
                    NavigationLink {
                        WorkoutDetailView(session: point.workoutSession)
                    } label: {
                        SessionBreakdownRow(point: point, unit: unit)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40))
                .foregroundColor(.appMuted)
            Text("No history yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text("Log this exercise to see progress here.")
                .font(.system(size: 13))
                .foregroundColor(.appMuted)
        }
        .padding(40)
    }

    // MARK: - PR header

    /// Top-of-screen card: actual top set + Epley estimated 1-rep max.
    /// e1RM gives serious lifters a normalized progression metric;
    /// shown as the secondary line so casual users still get the
    /// concrete "I lifted X for Y reps" number first.
    @ViewBuilder
    private func prHeader(top: WorkoutSet) -> some View {
        let e1rm = epley1RM(weight: top.weight, reps: top.reps)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("PERSONAL RECORD")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appMuted)
                    .kerning(0.8)
                Spacer()
                if e1rm > 0 {
                    Text("est. 1RM \(formatWeight(e1rm)) \(unit)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.appAccent)
                }
            }
            Text("\(formatWeight(top.weight)) \(unit) × \(top.reps)")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Max weight per session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if let last = chartData.last {
                    Text(last.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 11))
                        .foregroundColor(.appMuted)
                }
            }
            .padding(.bottom, 4)

            Chart(chartData) { point in
                LineMark(
                    x: .value("Session", point.session),
                    y: .value("Weight", point.maxWeight),
                )
                .foregroundStyle(Color.appAccent)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Session", point.session),
                    y: .value("Weight", point.maxWeight),
                )
                .foregroundStyle(Color.appAccent)
                .symbolSize(50)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisValueLabel()
                        .foregroundStyle(Color.appMuted)
                        .font(.system(size: 11))
                }
            }
            .frame(height: 140)
        }
        .padding(16)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }

    // MARK: - Helpers

    /// Epley formula: weight × (1 + reps / 30). Returns 0 for invalid
    /// inputs so callers can skip rendering the secondary line.
    /// Industry-standard for normalizing strength across rep ranges;
    /// sufficient for app-level "did I get stronger" questions.
    private func epley1RM(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return (weight * (1 + Double(reps) / 30.0)).rounded()
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(w))"
            : String(format: "%.1f", w)
    }
}

// MARK: - Per-session breakdown row
//
// Same role as the old HistoryView.SessionRow: shows date + every
// set the user logged for this exercise during that session as
// chips. Tappable -> WorkoutDetailView (full session snapshot).

struct SessionBreakdownRow: View {
    let point: ChartPoint
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(point.sets.count) set\(point.sets.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundColor(.appMuted)
            }
            FlowLayout(spacing: 6) {
                ForEach(point.sets) { s in
                    Text(setChipLabel(for: s, unit: unit))
                        .font(.system(size: 12))
                        .foregroundColor(.appMuted2)
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.appCard2)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }

    /// Render a set as a chip. Timed sets show duration; rep sets show
    /// reps. Mirrors the convention used in WorkoutDetailView.
    private func setChipLabel(for s: WorkoutSet, unit: String) -> String {
        if s.isTimed, let dur = s.durationSeconds {
            return "\(Int(s.weight))\(unit) × \(formatDuration(dur))"
        }
        return "\(Int(s.weight))\(unit) × \(s.reps)"
    }

    private func formatDuration(_ total: Int) -> String {
        let s = max(0, total)
        if s < 3600 {
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%d:%02d:%02d", h, m, sec)
    }
}

// MARK: - Shared chart point + flow layout
//
// ChartPoint and FlowLayout used to live inside HistoryView. Hoisted
// to file scope here so HistoryView can reuse them as well (the
// home tab's exercise-progress cards build mini ChartPoint sequences
// via the same shape). FlowLayout is unchanged from its prior version
// just relocated.

struct ChartPoint: Identifiable {
    let id = UUID()
    let session: Int
    let maxWeight: Double
    let date: Date
    let sets: [WorkoutSet]
    let workoutSession: WorkoutSession
}

/// Wrapping horizontal layout used to render set-chip rows where the
/// total width is unpredictable. Borrowed pattern from the previous
/// HistoryView implementation.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size),
            )
        }
    }

    private struct Layout {
        let frames: [CGRect]
        let size: CGSize
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> Layout {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalSize = CGSize.zero

        for subview in subviews {
            let s = subview.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, !frames.isEmpty {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: s.width, height: s.height))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            totalSize.width = max(totalSize.width, x - spacing)
            totalSize.height = y + rowHeight
        }
        return Layout(frames: frames, size: totalSize)
    }
}
