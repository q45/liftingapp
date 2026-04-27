// WorkoutDetailView.swift
// Snapshot view for a single completed workout.
//
// Opens when the user taps a workout row from Home / History. Design
// goals (per user feedback):
//
//   - Show *everything* in one scroll, not one exercise at a time.
//     Every exercise, every set, every weight × reps visible inline
//     without tapping to expand.
//   - Summary up top: date, duration, exercise count, set count,
//     total volume -- the whole session in five numbers.
//   - Per-exercise comparison against the user's most recent prior
//     session for the same exercise ("↑ from 180 × 5 on Apr 18")
//     so the value of logging becomes obvious at a glance.
//
// Non-goals for v1:
//
//   - Editing from here. If you need to correct a typo, resume the
//     workout (HomeView context menu) or delete + redo. The detail
//     view is deliberately read-only so users treat it as a snapshot.
//   - PR detection. Worth adding later but adds logic (all-time best
//     per exercise per rep count). Keep this view cheap and honest
//     for v1.

import SwiftUI
import SwiftData

struct WorkoutDetailView: View {
    let session: WorkoutSession

    /// All completed sessions, newest-first. Used for per-exercise
    /// comparisons -- for each exercise in `session` we look backward
    /// in `allSessions` to find the most recent prior occurrence.
    @Query(sort: \WorkoutSession.endTime, order: .reverse)
    private var allSessions: [WorkoutSession]

    @AppStorage("weightUnit") private var unit = "lbs"

    /// Live, ordered exercises of the session. Cached once per render
    /// so the body doesn't re-sort on every subview.
    private var exercises: [ExerciseEntry] { session.orderedExercises }

    /// Pre-built index of "most recent prior session per exercise
    /// name". Computed once per render to avoid an O(n) lookup inside
    /// each row. Keys are case-insensitive exercise names; values are
    /// the prior session + its matching ExerciseEntry.
    ///
    /// "Prior" = endTime strictly less than `session.endTime`. Sessions
    /// completed at the same instant (rare) are treated as ties with
    /// the older-first ordering from `allSessions`.
    private var priorByExercise: [String: (session: WorkoutSession, entry: ExerciseEntry)] {
        var out: [String: (WorkoutSession, ExerciseEntry)] = [:]
        for prior in allSessions where prior.isLive
            && prior.isCompleted
            && prior.id != session.id
            && prior.endTime < session.endTime
        {
            for ex in prior.liveExercises {
                let key = ex.name.trimmingCharacters(in: .whitespaces).lowercased()
                // `allSessions` is newest-first; first hit wins.
                if out[key] == nil {
                    out[key] = (prior, ex)
                }
            }
        }
        return out
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                        .padding(.horizontal, 20)

                    if exercises.isEmpty {
                        emptyState
                            .padding(.horizontal, 20)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(exercises, id: \.id) { ex in
                                ExerciseSnapshotCard(
                                    exercise: ex,
                                    prior: priorByExercise[
                                        ex.name.trimmingCharacters(in: .whitespaces).lowercased()
                                    ],
                                    unit: unit,
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle(session.endTime.formatted(.dateTime.weekday(.wide).month().day()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.endTime.formatted(.dateTime.weekday(.abbreviated).month().day().year()))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.appMuted)
                        .kerning(0.6)
                        .textCase(.uppercase)
                    Text(session.durationString)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                Spacer()
                Text("\(session.totalSets) sets")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.appAccent.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.appAccent.opacity(0.3), lineWidth: 1))
            }

            HStack(spacing: 0) {
                summaryMetric(value: "\(exercises.count)", label: "exercises")
                divider
                summaryMetric(value: "\(session.totalSets)", label: "sets")
                divider
                summaryMetric(value: volumeText, label: "volume \(unit)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var emptyState: some View {
        Text("This workout has no logged sets.")
            .font(.system(size: 14))
            .foregroundColor(.appMuted)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appCard)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func summaryMetric(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.4)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.appBorder)
            .frame(width: 1, height: 28)
    }

    private var volumeText: String {
        let v = session.totalVolume
        if v == 0 { return "—" }
        if v >= 1000 {
            return String(format: "%.1fk", v / 1000)
        }
        return "\(Int(v))"
    }
}

// MARK: - Exercise snapshot card

/// One exercise within the detail view. Renders the full set table
/// (no tap-to-expand) plus a comparison line beneath.
private struct ExerciseSnapshotCard: View {
    let exercise: ExerciseEntry
    /// Prior session + entry for the same exercise, if any. Drives
    /// the comparison chip at the bottom of the card.
    let prior: (session: WorkoutSession, entry: ExerciseEntry)?
    let unit: String

    private var orderedSets: [WorkoutSet] { exercise.orderedSets }

    /// Top set for THIS exercise in THIS session. Defined as heaviest
    /// weight; ties broken by reps. Nil when there are no sets.
    private var topSet: WorkoutSet? {
        orderedSets.max(by: { a, b in
            a.weight < b.weight || (a.weight == b.weight && a.reps < b.reps)
        })
    }

    /// Prior session's top set using the same rules.
    private var priorTop: WorkoutSet? {
        guard let entry = prior?.entry else { return nil }
        return entry.orderedSets.max(by: { a, b in
            a.weight < b.weight || (a.weight == b.weight && a.reps < b.reps)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.appBorder).padding(.horizontal, 14)
            setsTable
            if !orderedSets.isEmpty {
                Divider().background(Color.appBorder).padding(.horizontal, 14)
                comparisonRow
            }
        }
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
    }

    // MARK: Subviews

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(categoryColor(exercise.category))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.appMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// "3 sets · top 185 lbs × 5" (or "No sets logged"). Built once
    /// rather than inline so the conditional stays legible. Timed
    /// sets render the duration in place of reps.
    private var headerSubtitle: String {
        let setWord = orderedSets.count == 1 ? "set" : "sets"
        guard let top = topSet else { return "No sets logged" }
        let topMeasure = top.isTimed
            ? formatDuration(top.durationSeconds ?? 0)
            : "\(top.reps) rep\(top.reps == 1 ? "" : "s")"
        return "\(orderedSets.count) \(setWord) · top \(formatWeight(top.weight)) \(unit) × \(topMeasure)"
    }

    @ViewBuilder
    private var setsTable: some View {
        if orderedSets.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                // Column headers
                HStack {
                    Text("#").frame(width: 24, alignment: .leading)
                    Text("Weight").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Reps").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Vol").frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.4)
                .textCase(.uppercase)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 6)

                ForEach(Array(orderedSets.enumerated()), id: \.element.id) { i, s in
                    HStack {
                        Text("\(i + 1)")
                            .frame(width: 24, alignment: .leading)
                            .foregroundColor(.appMuted)
                        HStack(spacing: 2) {
                            Text(formatWeight(s.weight))
                                .fontWeight(.semibold)
                            Text(unit).foregroundColor(.appMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if s.isTimed, let dur = s.durationSeconds {
                            HStack(spacing: 4) {
                                Text(formatDuration(dur))
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                Image(systemName: "timer")
                                    .font(.system(size: 11))
                                    .foregroundColor(.appMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("—")
                                .frame(width: 52, alignment: .trailing)
                                .foregroundColor(.appMuted)
                        } else {
                            HStack(spacing: 2) {
                                Text("\(s.reps)").fontWeight(.semibold)
                                Text("reps").foregroundColor(.appMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(Int(s.weight * Double(s.reps)))")
                                .frame(width: 52, alignment: .trailing)
                                .foregroundColor(.appMuted)
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    if i < orderedSets.count - 1 {
                        Divider().background(Color.appBorder).padding(.horizontal, 14)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Comparison row

    /// "↑ from 180 × 5 on Apr 18" / "Same as Apr 18" / "↓ from 190 × 5
    /// on Apr 18" / "First time logging this". Compares top sets,
    /// since that's what lifters intuitively track for progression.
    @ViewBuilder
    private var comparisonRow: some View {
        let model = comparisonModel
        HStack(spacing: 8) {
            Image(systemName: model.iconName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(model.color)
            Text(model.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.appMuted2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private enum ComparisonDirection {
        case up, down, same, firstTime
    }

    private struct ComparisonModel {
        let direction: ComparisonDirection
        let text: String
        let iconName: String
        let color: Color
    }

    /// Build the comparison copy. Kept in one place so the icon, color,
    /// and string can never disagree with the actual delta. Branches
    /// on top.isTimed because the "what got better" rule differs:
    /// for rep sets we compare weight+reps, for timed sets we compare
    /// weight+duration. Mixed-mode sessions (rep vs. timed for the
    /// same exercise) are rare enough that we just fall back to
    /// "First time" rather than build a cross-mode delta.
    private var comparisonModel: ComparisonModel {
        guard let top = topSet else {
            // Shouldn't render -- comparisonRow is gated on non-empty
            // sets -- but a safe fallback avoids a crash if that
            // invariant ever breaks.
            return ComparisonModel(
                direction: .firstTime,
                text: "No sets",
                iconName: "minus",
                color: .appMuted,
            )
        }

        guard let prior, let priorTop, top.isTimed == priorTop.isTimed else {
            return ComparisonModel(
                direction: .firstTime,
                text: "First time logging this",
                iconName: "sparkles",
                color: .appAccent,
            )
        }

        let priorDate = prior.session.endTime.formatted(
            .dateTime.month(.abbreviated).day(),
        )

        let priorSummary: String
        let isUp: Bool
        let isDown: Bool
        if top.isTimed {
            // Timed sets: compare (weight, duration). Heavier weight
            // wins; same weight + longer hold is "up".
            let topDur = top.durationSeconds ?? 0
            let priorDur = priorTop.durationSeconds ?? 0
            priorSummary = "\(formatWeight(priorTop.weight)) \(unit) × \(formatDuration(priorDur))"
            isUp = top.weight > priorTop.weight
                || (top.weight == priorTop.weight && topDur > priorDur)
            isDown = top.weight < priorTop.weight
                || (top.weight == priorTop.weight && topDur < priorDur)
        } else {
            // Rep sets: compare (weight, reps). Same rule as before.
            priorSummary = "\(formatWeight(priorTop.weight)) \(unit) × \(priorTop.reps)"
            isUp = top.weight > priorTop.weight
                || (top.weight == priorTop.weight && top.reps > priorTop.reps)
            isDown = top.weight < priorTop.weight
                || (top.weight == priorTop.weight && top.reps < priorTop.reps)
        }

        if isUp {
            return ComparisonModel(
                direction: .up,
                text: "↑ up from \(priorSummary) on \(priorDate)",
                iconName: "arrow.up.right",
                color: .appGreen,
            )
        } else if isDown {
            return ComparisonModel(
                direction: .down,
                text: "↓ down from \(priorSummary) on \(priorDate)",
                iconName: "arrow.down.right",
                color: .appRed,
            )
        } else {
            return ComparisonModel(
                direction: .same,
                text: "Same as \(priorDate): \(priorSummary)",
                iconName: "equal",
                color: .appMuted,
            )
        }
    }

    // MARK: Formatting

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(w))"
            : String(format: "%.1f", w)
    }

    /// Mirrors SetLoggerView / ExerciseCard's duration formatter --
    /// "0:30" / "1:30" / "1:05:00". Local copy keeps this view
    /// independent of either of those.
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
