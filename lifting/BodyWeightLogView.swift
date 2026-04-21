// BodyWeightLogView.swift
// Time-series log of body weight. Lives under Profile -> Body weight.
//
// Two responsibilities:
//
//   1. Show the chronological history (newest first) of all weigh-ins
//      the user has logged. Swipe to delete (soft delete -- propagates
//      to server via SyncEngine).
//
//   2. Sheet for entering a new weigh-in: weight (required, in the
//      user's preferred unit), measured-at date (defaults to now),
//      optional notes.
//
// Canonical storage is kg. We convert at the UI edge so the server
// doesn't have to care about units per row -- every body_weight_logs
// row on the server is kg, forever.

import SwiftUI
import SwiftData

struct BodyWeightLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<BodyWeightEntry> { $0.deletedAt == nil },
        sort: \BodyWeightEntry.measuredAt,
        order: .reverse,
    ) private var entries: [BodyWeightEntry]

    // Preferred unit is read off the UserProfile singleton. We don't
    // force a default here -- if the user hasn't set one, we fall back
    // to lbs which is the most common US default.
    @Query private var profiles: [UserProfile]
    private var usesKg: Bool { (profiles.first?.preferredUnit ?? "lbs") == "kg" }

    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                if entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Body weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.appMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.appAccent)
                            .bold()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAddSheet) {
            AddBodyWeightSheet(usesKg: usesKg)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scalemass")
                .font(.system(size: 40))
                .foregroundColor(.appMuted)
            Text("No weigh-ins yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text(
                "Log your weight periodically. Your AI coach uses the latest entry when making recommendations.",
            )
            .font(.system(size: 13))
            .foregroundColor(.appMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            Button {
                showAddSheet = true
            } label: {
                Text("Log first weigh-in")
            }
            .buttonStyle(AccentButtonStyle())
            .padding(.horizontal, 40)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            ForEach(entries, id: \.id) { entry in
                row(for: entry)
                    .listRowBackground(Color.appCard)
                    .listRowSeparatorTint(Color.appBorder)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            delete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(for entry: BodyWeightEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayWeight(entry.weightKg))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                if let notes = entry.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 12))
                        .foregroundColor(.appMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(relativeDate(entry.measuredAt))
                .font(.system(size: 13))
                .foregroundColor(.appMuted)
        }
        .padding(.vertical, 4)
    }

    private func displayWeight(_ kg: Double) -> String {
        let value = usesKg ? kg : kg * 2.20462
        let rounded = (value * 10).rounded() / 10
        let unit = usesKg ? "kg" : "lbs"
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) \(unit)"
        }
        return String(format: "%.1f \(unit)", rounded)
    }

    private func relativeDate(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        // Clamp to past/today; "in 0 seconds" looks silly.
        let clamped = min(date, Date())
        return fmt.localizedString(for: clamped, relativeTo: Date())
    }

    private func delete(_ entry: BodyWeightEntry) {
        entry.markDeleted()
        try? modelContext.save()
        SyncEngine.shared?.scheduleSync()
    }
}

// MARK: - Add sheet

/// Simple add-weigh-in sheet. Presented from BodyWeightLogView's +
/// button. Kept as a private-ish view (file-scoped) because it's the
/// only caller and doesn't benefit from reuse.
private struct AddBodyWeightSheet: View {
    let usesKg: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var weightText: String = ""
    @State private var measuredAt: Date = .now
    @State private var notes: String = ""
    @State private var validationError: String?

    private var trimmedWeight: String {
        weightText.trimmingCharacters(in: .whitespaces)
    }

    /// Parsed, converted-to-kg weight. Nil if input is empty or
    /// invalid. Bounds-checked in `save()` against a reasonable range
    /// so fat-fingered entries (3 kg, 9999 kg) don't reach the server
    /// only to bounce on its Zod guard.
    private var parsedWeightKg: Double? {
        guard let v = Double(trimmedWeight), v > 0 else { return nil }
        return usesKg ? v : v / 2.20462
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                Form {
                    Section {
                        LabeledContent(usesKg ? "Weight (kg)" : "Weight (lbs)") {
                            TextField(
                                "",
                                text: $weightText,
                                prompt: Text(usesKg ? "e.g. 80.5" : "e.g. 178")
                                    .foregroundColor(.appMuted),
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.white)
                        }
                        .listRowBackground(Color.appCard)

                        DatePicker(
                            "Measured",
                            selection: $measuredAt,
                            in: ...Date(),
                            displayedComponents: .date,
                        )
                        .foregroundColor(.white)
                        .listRowBackground(Color.appCard)
                    }

                    Section {
                        TextField(
                            "",
                            text: $notes,
                            prompt: Text("e.g. morning, pre-workout")
                                .foregroundColor(.appMuted),
                        )
                        .foregroundColor(.white)
                        .listRowBackground(Color.appCard)
                    } header: {
                        SectionLabel(text: "Notes (optional)")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.appBg)
            }
            .navigationTitle("Log weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.appMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .foregroundColor(.appAccent)
                        .bold()
                        .disabled(parsedWeightKg == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Couldn't save", isPresented: Binding(
            get: { validationError != nil },
            set: { if !$0 { validationError = nil } },
        )) {
            Button("OK") { validationError = nil }
        } message: {
            Text(validationError ?? "")
        }
    }

    private func save() {
        guard let kg = parsedWeightKg else {
            validationError = "Please enter a valid weight."
            return
        }
        // Server-side Zod enforces 20..500 kg. Mirror client-side so a
        // typo's rejected without a round-trip.
        guard (20...500).contains(kg) else {
            validationError = "That weight is outside the allowed range."
            return
        }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = BodyWeightEntry(
            weightKg: kg,
            measuredAt: measuredAt,
            notes: trimmedNotes.isEmpty ? nil : String(trimmedNotes.prefix(200)),
        )
        modelContext.insert(entry)
        try? modelContext.save()
        SyncEngine.shared?.scheduleSync()
        dismiss()
    }
}
