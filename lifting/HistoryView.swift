// HistoryView.swift
// Workout history dashboard.
//
// Four stacked sections, ordered glanceable -> deep:
//
//   1. THIS WEEK         -- workouts done this week + per-day dots.
//   2. LAST 12 WEEKS     -- GitHub-style heatmap + longest streak.
//   3. PERSONAL RECORDS  -- top set per exercise + estimated 1RM.
//   4. EXERCISE PROGRESS -- mini chart per exercise with last entry.
//
// Sections 3 and 4 push to ExerciseProgressView for the per-exercise
// drilldown (the chart + session breakdown that used to be the whole
// History tab). The redesign is informed by the observation that
// most "checking history" intents are aggregate questions ("am I
// training enough", "am I getting stronger") rather than
// exercise-specific deep dives -- and the per-session "what did I do
// that day" question is already covered by Home -> Recent ->
// WorkoutDetailView.

import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Query(sort: \WorkoutSession.endTime) private var allSessions: [WorkoutSession]
    @AppStorage("weightUnit") private var unit = "lbs"

    /// Completed, non-tombstoned workouts only -- everything below
    /// derives from this base list, never from the raw query.
    private var workouts: [WorkoutSession] {
        allSessions.filter { $0.isLive && $0.isCompleted }
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
        .refreshable { await SyncEngine.shared?.syncNow() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Empty state

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

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ThisWeekSection(workouts: workouts, unit: unit)
                    .padding(.horizontal, 20)

                ActivityHeatmapSection(workouts: workouts)
                    .padding(.horizontal, 20)

                PersonalRecordsSection(workouts: workouts, unit: unit)
                    .padding(.horizontal, 20)

                ExerciseProgressSection(workouts: workouts, unit: unit)
                    .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - Section 1: This Week
//
// Day-dot row + workout count + total volume. Read in <1 second.
// Treats the "week" as the user's locale-aware week (Mon-start in
// most of the world, Sun-start in the US) via Calendar.

private struct ThisWeekSection: View {
    let workouts: [WorkoutSession]
    let unit: String

    /// 7-day window starting from the locale-derived first weekday.
    private var weekDates: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        // Offset back to the start of the user's calendar week.
        let weekday = cal.component(.weekday, from: today) // 1...7
        let firstWeekday = cal.firstWeekday
        let daysBack = (weekday - firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -daysBack, to: today) else {
            return []
        }
        return (0..<7).compactMap {
            cal.date(byAdding: .day, value: $0, to: start)
        }
    }

    /// Set of "start of day" Dates we have at least one workout for.
    /// Cached once per render so the dot row's lookups are O(1).
    private var trainingDays: Set<Date> {
        let cal = Calendar.current
        return Set(workouts.map { cal.startOfDay(for: $0.endTime) })
    }

    private var weekWorkouts: [WorkoutSession] {
        guard let start = weekDates.first else { return [] }
        return workouts.filter { $0.endTime >= start }
    }

    private var totalVolume: Double {
        weekWorkouts.reduce(0) { $0 + $1.totalVolume }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "This Week")
                Spacer()
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    statCell(
                        value: "\(weekWorkouts.count)",
                        label: weekWorkouts.count == 1 ? "workout" : "workouts",
                    )
                    statCell(
                        value: totalVolume > 0
                            ? formatVolume(totalVolume)
                            : "—",
                        label: "vol \(unit)",
                    )
                }

                dotRow
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func statCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.5)
                .textCase(.uppercase)
        }
    }

    @ViewBuilder
    private var dotRow: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        HStack(spacing: 0) {
            ForEach(weekDates, id: \.self) { day in
                let trained = trainingDays.contains(day)
                let isToday = cal.isDate(day, inSameDayAs: today)
                VStack(spacing: 6) {
                    Text(dayLabel(day))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.appMuted)
                        .kerning(0.4)
                    ZStack {
                        Circle()
                            .fill(trained ? Color.appAccent : Color.clear)
                            .frame(width: 14, height: 14)
                        Circle()
                            .stroke(
                                trained ? Color.appAccent
                                    : (isToday ? Color.appMuted : Color.appBorder),
                                lineWidth: isToday && !trained ? 1.5 : 1,
                            )
                            .frame(width: 14, height: 14)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide))): \(trained ? "trained" : "rest")")
            }
        }
    }

    /// "M", "T", "W"... using the locale-aware first letter.
    private func dayLabel(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.narrow))
    }

    private func formatVolume(_ v: Double) -> String {
        if v >= 1000 {
            return String(format: "%.1fk", v / 1000)
        }
        return "\(Int(v))"
    }
}

// MARK: - Section 2: Activity heatmap (last 12 weeks)
//
// 7-row x 12-column grid, rows = days of the week, columns = weeks
// (oldest left, current right). Filled cells = trained that day.
// Mirrors the iconic GitHub contributions chart, which lifters tend
// to find immediately legible. Below: longest training streak.

private struct ActivityHeatmapSection: View {
    let workouts: [WorkoutSession]

    /// 12 weeks * 7 days = 84 cells, ordered week-major (col-major).
    /// Each cell is a (date, trained) pair. Computed once per render.
    private var cells: [[Cell]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let weekday = cal.component(.weekday, from: today)
        let firstWeekday = cal.firstWeekday
        let daysBackToWeekStart = (weekday - firstWeekday + 7) % 7
        guard let weekStart = cal.date(
            byAdding: .day,
            value: -daysBackToWeekStart,
            to: today,
        ) else { return [] }

        let trainingDays: Set<Date> = Set(
            workouts.map { cal.startOfDay(for: $0.endTime) },
        )

        var weeks: [[Cell]] = []
        for w in 0..<12 {
            // -11..0 to align oldest week left, current week right.
            let weeksAgo = 11 - w
            guard let weekDay0 = cal.date(
                byAdding: .day,
                value: -7 * weeksAgo,
                to: weekStart,
            ) else { continue }
            var col: [Cell] = []
            for d in 0..<7 {
                if let date = cal.date(byAdding: .day, value: d, to: weekDay0) {
                    col.append(Cell(date: date, trained: trainingDays.contains(date)))
                }
            }
            weeks.append(col)
        }
        return weeks
    }

    /// Longest run of consecutive training days within the last 12-week
    /// window. Doesn't extend past the window even if the user trained
    /// every day for a year -- keeps the implementation O(84).
    private var longestStreak: Int {
        let flat = cells.flatMap { $0 }.sorted { $0.date < $1.date }
        var best = 0
        var current = 0
        for c in flat {
            if c.trained {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Activity")
                Spacer()
                Text("Last 12 weeks")
                    .font(.system(size: 11))
                    .foregroundColor(.appMuted)
            }

            VStack(alignment: .leading, spacing: 12) {
                grid
                Divider().background(Color.appBorder)
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.appAccent)
                    Text("Longest streak: \(longestStreak) day\(longestStreak == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundColor(.appMuted2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appBorder, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var grid: some View {
        // Each "column" in the layout is a week; cells stack
        // vertically (Mon..Sun-style). Use HStack of VStacks rather
        // than LazyHGrid to keep the tile sizes predictable.
        HStack(spacing: 4) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 4) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(cell.trained ? Color.appAccent : Color.appCard2)
                            .frame(width: 14, height: 14)
                    }
                }
            }
        }
    }

    private struct Cell {
        let date: Date
        let trained: Bool
    }
}

// MARK: - Section 3: Personal records
//
// Top set per exercise. Sorted by raw weight descending so the
// heaviest lifts surface first; ties broken by reps. Each row shows
// the actual top set ("225 × 5") plus an estimated 1RM badge that
// gives serious lifters a normalized progression metric.

private struct PersonalRecordsSection: View {
    let workouts: [WorkoutSession]
    let unit: String

    /// Maximum number of PR rows to surface inline. The "View all ->"
    /// link doesn't go anywhere yet (no dedicated PRs screen) so we
    /// just don't cap if there are 6 rather than 5; better to let
    /// users see the full picture for now.
    private let inlineLimit = 6

    private var prs: [PR] {
        // Bucket sets by exercise name (case-insensitive). For each
        // bucket find the heaviest set with reps tiebreaker.
        var buckets: [String: (display: String, category: String, top: WorkoutSet)] = [:]
        for w in workouts {
            for ex in w.liveExercises {
                let key = ex.name.trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty else { continue }
                for s in ex.liveSets {
                    // Skip pure-time sets from PR ranking -- "PR" is
                    // a weight concept; timed records belong on a
                    // future screen, not interleaved here.
                    if s.isTimed { continue }
                    if let cur = buckets[key] {
                        if s.weight > cur.top.weight
                            || (s.weight == cur.top.weight && s.reps > cur.top.reps)
                        {
                            buckets[key] = (ex.name, ex.category, s)
                        }
                    } else {
                        buckets[key] = (ex.name, ex.category, s)
                    }
                }
            }
        }
        return buckets.values
            .map { PR(name: $0.display, category: $0.category, top: $0.top) }
            .sorted { lhs, rhs in
                if lhs.top.weight != rhs.top.weight {
                    return lhs.top.weight > rhs.top.weight
                }
                return lhs.top.reps > rhs.top.reps
            }
    }

    var body: some View {
        if prs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Personal Records")
                    Spacer()
                }

                VStack(spacing: 8) {
                    ForEach(prs.prefix(inlineLimit)) { pr in
                        NavigationLink {
                            ExerciseProgressView(exerciseName: pr.name)
                        } label: {
                            PRRow(pr: pr, unit: unit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    struct PR: Identifiable {
        let id = UUID()
        let name: String
        let category: String
        let top: WorkoutSet
    }
}

private struct PRRow: View {
    let pr: PersonalRecordsSection.PR
    let unit: String

    /// Epley formula: weight × (1 + reps/30). Standard normalization
    /// for "what could this lifter do for one rep" -- lets a user
    /// compare a 5-rep PR against a 3-rep PR fairly.
    private var e1RM: Int {
        guard pr.top.weight > 0, pr.top.reps > 0 else { return 0 }
        return Int((pr.top.weight * (1 + Double(pr.top.reps) / 30.0)).rounded())
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(categoryColor(pr.category))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("est. 1RM \(e1RM) \(unit)")
                    .font(.system(size: 11))
                    .foregroundColor(.appMuted)
            }
            Spacer()
            HStack(spacing: 2) {
                Text("\(formatWeight(pr.top.weight))")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundColor(.appMuted)
                Text("× \(pr.top.reps)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appMuted2)
                    .padding(.leading, 4)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.appMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(w))"
            : String(format: "%.1f", w)
    }
}

// MARK: - Section 4: Exercise progress cards
//
// One card per exercise (top by recency / frequency), each with a
// tiny line chart of max weight per session. Tapping pushes to
// ExerciseProgressView for the deep dive. Caps to the top N to
// keep the page from becoming an infinite scroll; the rest live in
// the per-exercise drilldown anyway.

private struct ExerciseProgressSection: View {
    let workouts: [WorkoutSession]
    let unit: String

    private let maxCards = 8

    /// Exercises ranked by (frequency desc, last-seen desc). Frequency
    /// favors lifts the user does consistently; recency tiebreaks so
    /// new programs surface even before they have a long history.
    private var rankedExercises: [Exercise] {
        struct Bucket {
            var name: String
            var category: String
            var sessionCount: Int = 0
            var lastSeen: Date = .distantPast
            var points: [ChartPoint] = []
        }

        var buckets: [String: Bucket] = [:]
        for (idx, w) in workouts.sorted(by: { $0.endTime < $1.endTime }).enumerated() {
            for ex in w.liveExercises where !ex.liveSets.isEmpty {
                let key = ex.name.trimmingCharacters(in: .whitespaces).lowercased()
                if buckets[key] == nil {
                    buckets[key] = Bucket(name: ex.name, category: ex.category)
                }
                let maxWeight = ex.orderedSets.map(\.weight).max() ?? 0
                buckets[key]!.sessionCount += 1
                buckets[key]!.lastSeen = max(buckets[key]!.lastSeen, w.endTime)
                buckets[key]!.points.append(
                    ChartPoint(
                        session: idx + 1,
                        maxWeight: maxWeight,
                        date: w.endTime,
                        sets: ex.orderedSets,
                        workoutSession: w,
                    ),
                )
            }
        }

        return buckets.values
            .map { b in
                Exercise(
                    name: b.name,
                    category: b.category,
                    sessionCount: b.sessionCount,
                    lastSeen: b.lastSeen,
                    points: b.points,
                )
            }
            .sorted { a, b in
                if a.sessionCount != b.sessionCount {
                    return a.sessionCount > b.sessionCount
                }
                return a.lastSeen > b.lastSeen
            }
    }

    var body: some View {
        let visible = Array(rankedExercises.prefix(maxCards))
        if visible.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Exercise Progress")
                    Spacer()
                }

                VStack(spacing: 10) {
                    ForEach(visible) { ex in
                        NavigationLink {
                            ExerciseProgressView(exerciseName: ex.name)
                        } label: {
                            ProgressCard(exercise: ex, unit: unit)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if rankedExercises.count > visible.count {
                    Text("\(rankedExercises.count - visible.count) more in your history.")
                        .font(.system(size: 11))
                        .foregroundColor(.appMuted)
                        .padding(.top, 4)
                }
            }
        }
    }

    struct Exercise: Identifiable {
        var id: String { name }
        let name: String
        let category: String
        let sessionCount: Int
        let lastSeen: Date
        let points: [ChartPoint]
    }
}

private struct ProgressCard: View {
    let exercise: ExerciseProgressSection.Exercise
    let unit: String

    private var lastPoint: ChartPoint? { exercise.points.last }

    /// "Last: 185 × 5 · 3d ago". Time-since rendering goes via
    /// RelativeDateTimeFormatter so we get "today" / "yesterday" /
    /// "3d ago" without writing three branches by hand.
    private var lastEntryLabel: String {
        guard let last = lastPoint else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let topSet = last.sets.max { a, b in
            a.weight < b.weight || (a.weight == b.weight && a.reps < b.reps)
        }
        guard let s = topSet else { return "" }
        let topMeasure = s.isTimed
            ? formatDuration(s.durationSeconds ?? 0)
            : "\(s.reps)"
        return "Last: \(formatWeight(s.weight)) \(unit) × \(topMeasure)  ·  \(f.localizedString(for: last.date, relativeTo: Date()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(categoryColor(exercise.category))
                    .frame(width: 8, height: 8)
                Text(exercise.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(exercise.sessionCount) session\(exercise.sessionCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(.appMuted)
            }

            // Mini line chart. Hide axes/labels to keep the card
            // visually quiet -- the trend shape is the signal here,
            // not the absolute numbers (those live in the drilldown).
            if exercise.points.count >= 2 {
                Chart(exercise.points) { p in
                    LineMark(
                        x: .value("Session", p.session),
                        y: .value("Weight", p.maxWeight),
                    )
                    .foregroundStyle(Color.appAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Session", p.session),
                        y: .value("Weight", p.maxWeight),
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.appAccent.opacity(0.18),
                                Color.appAccent.opacity(0.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom,
                        ),
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 48)
            } else {
                // Single-data-point fallback: a small flat bar so the
                // card layout stays consistent.
                Text("Log this exercise again to see a trend line.")
                    .font(.system(size: 11))
                    .foregroundColor(.appMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            HStack {
                Text(lastEntryLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.appMuted2)
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

    private func formatWeight(_ w: Double) -> String {
        w.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(w))"
            : String(format: "%.1f", w)
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
