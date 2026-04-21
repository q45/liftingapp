// HistoryView.swift
// Workout history with per-exercise progress chart using Swift Charts

import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Query(sort: \WorkoutSession.endTime) private var allSessions: [WorkoutSession]
    @AppStorage("weightUnit") private var unit = "lbs"

    /// Only show completed, non-deleted sessions. Active sessions live
    /// under `WorkoutManager`; soft-deleted ones carry a `deletedAt`.
    private var workouts: [WorkoutSession] {
        allSessions.filter { $0.isLive && $0.isCompleted }
    }

    private var allExerciseNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for w in workouts {
            for ex in w.orderedExercises {
                if seen.insert(ex.name).inserted { result.append(ex.name) }
            }
        }
        return result
    }

    @State private var selectedExercise: String? = nil

    struct ChartPoint: Identifiable {
        let id = UUID()
        let session: Int
        let maxWeight: Double
        let date: Date
        let sets: [WorkoutSet]
    }

    private var chartData: [ChartPoint] {
        guard let name = selectedExercise else { return [] }
        let relevant = workouts.filter { $0.liveExercises.contains { $0.name == name } }
        return relevant.enumerated().compactMap { i, w in
            guard let ex = w.liveExercises.first(where: { $0.name == name }),
                  !ex.liveSets.isEmpty else { return nil }
            return ChartPoint(
                session: i + 1,
                maxWeight: ex.orderedSets.map(\.weight).max() ?? 0,
                date: w.endTime,
                sets: ex.orderedSets,
            )
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                if workouts.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear {
            if selectedExercise == nil { selectedExercise = allExerciseNames.first }
        }
        .onChange(of: allSessions.count) { _, _ in
            if selectedExercise == nil { selectedExercise = allExerciseNames.first }
        }
        .refreshable { await SyncEngine.shared?.syncNow() }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundColor(.appMuted)
            Text("No history yet")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            Text("Finish your first workout to see progress")
                .font(.system(size: 14))
                .foregroundColor(.appMuted)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Exercise selector chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(allExerciseNames, id: \.self) { name in
                            Button(name) { selectedExercise = name }
                                .font(.system(size: 12, weight: selectedExercise == name ? .bold : .medium))
                                .foregroundColor(selectedExercise == name ? .black : .appMuted2)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(selectedExercise == name ? Color.appAccent : Color.appCard)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(selectedExercise == name ? Color.appAccent : Color.appBorder, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 16)

                // Chart card
                if chartData.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedExercise ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(.appMuted)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(Int(chartData.last?.maxWeight ?? 0))")
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundColor(.white)
                            Text(unit)
                                .font(.system(size: 14))
                                .foregroundColor(.appMuted)

                            let delta = (chartData.last?.maxWeight ?? 0) - (chartData.first?.maxWeight ?? 0)
                            Text("\(delta >= 0 ? "↑" : "↓")\(Int(abs(delta))) from first")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(delta >= 0 ? .appGreen : .appRed)
                        }
                        .padding(.bottom, 12)

                        Chart(chartData) { point in
                            AreaMark(
                                x: .value("Session", point.session),
                                y: .value("Weight", point.maxWeight)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.appAccent.opacity(0.3), Color.appAccent.opacity(0)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            LineMark(
                                x: .value("Session", point.session),
                                y: .value("Weight", point.maxWeight)
                            )
                            .foregroundStyle(Color.appAccent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.catmullRom)

                            PointMark(
                                x: .value("Session", point.session),
                                y: .value("Weight", point.maxWeight)
                            )
                            .foregroundStyle(Color.appAccent)
                            .symbolSize(50)
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis {
                            AxisMarks(position: .trailing) { val in
                                AxisValueLabel()
                                    .foregroundStyle(Color.appMuted)
                                    .font(.system(size: 11))
                            }
                        }
                        .frame(height: 130)
                    }
                    .padding(16)
                    .background(Color.appCard)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }

                // Session breakdown
                ForEach(chartData.reversed()) { point in
                    SessionRow(point: point, unit: unit)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
    }
}

struct SessionRow: View {
    let point: HistoryView.ChartPoint
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(point.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(point.sets.count) sets")
                    .font(.system(size: 12))
                    .foregroundColor(.appMuted)
            }
            FlowLayout(spacing: 6) {
                ForEach(point.sets) { s in
                    Text("\(Int(s.weight))\(unit) × \(s.reps)")
                        .font(.system(size: 12))
                        .foregroundColor(.appMuted2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.appCard2)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }
}

// Simple horizontal flow layout for set chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}
