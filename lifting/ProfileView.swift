// ProfileView.swift
// Athlete profile: identity, training context, and goals the AI coach
// reads on every prompt build. Also houses the body-weight log entry
// point (separate sheet so the profile form stays short).
//
// Design notes:
//
// - The profile is singleton-per-user; we fetch the one row via @Query
//   and create it lazily on first save. No create/edit distinction.
//
// - Every field is optional. The UI renders as a Form with sensible
//   defaults (Picker "Select..." rows, empty text fields) and only
//   persists fields the user has explicitly touched. No validation
//   beyond server-side caps (age in a sane range, height/weight in
//   plausible bounds).
//
// - "Save" is a deliberate button rather than autosave. Autosaving on
//   every keystroke would thrash the sync queue and churn the cache
//   invalidation key on the AI coach. Explicit save == one sync push
//   per edit.
//
// - The form respects the user's preferred_unit for height/weight
//   display. Canonical storage is cm / kg; we convert at the UI edge.

import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [UserProfile]

    /// Unit is stored in two places:
    ///   - UserProfile.preferredUnit (canonical, synced to the server,
    ///     read by the AI coach when building its prompt)
    ///   - @AppStorage("weightUnit") (fast local read, consumed by
    ///     HomeView / WorkoutView / CoachView / LocalCoach for UI)
    /// ProfileView owns the "source of truth" UI: whenever the user
    /// changes units here, we write through to @AppStorage. On load,
    /// if the profile has a unit we copy it to @AppStorage so a
    /// server-synced change propagates next time the user opens this
    /// screen. See `loadFromModel()` and `save()`.
    @AppStorage("weightUnit") private var legacyUnitStore = "lbs"

    // Form state. Initialized from the loaded profile in .onAppear;
    // bound to the form widgets directly. We don't mirror the model
    // one-to-one because SwiftUI bindings on Int? / Double? require a
    // lot of boilerplate -- strings + parse-on-save is cleaner.
    @State private var birthYearText: String = ""
    @State private var heightText: String = ""
    @State private var trainingDaysText: String = ""
    @State private var notes: String = ""
    @State private var sex: String = ""
    @State private var experienceLevel: String = ""
    @State private var primaryGoal: String = ""
    @State private var equipmentAccess: String = ""
    @State private var preferredUnit: String = "lbs"

    @State private var showBodyWeightSheet = false
    @State private var saveError: String?

    private var currentProfile: UserProfile? { profiles.first }

    /// The user's imperial/metric preference, defaulting to lbs so a
    /// fresh profile shows pounds until they pick otherwise.
    private var usesKg: Bool { preferredUnit == "kg" }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                formBody
            }
            .navigationTitle("Profile")
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
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: loadFromModel)
        .alert("Couldn't save profile", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } },
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .sheet(isPresented: $showBodyWeightSheet) {
            BodyWeightLogView()
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var formBody: some View {
        Form {
            Section {
                // Body weight has its own sheet (separate from profile
                // form because it's a log, not a single value) so we
                // surface the latest entry + a "Log weight" row here
                // that pushes into BodyWeightLogView.
                bodyWeightRow
            } header: {
                SectionLabel(text: "Body weight")
            }

            Section {
                unitPicker
                birthYearField
                sexPicker
                heightField
            } header: {
                SectionLabel(text: "About you")
            }

            Section {
                experiencePicker
                goalPicker
                equipmentPicker
                trainingDaysField
            } header: {
                SectionLabel(text: "Training")
            }

            Section {
                notesField
            } header: {
                SectionLabel(text: "Constraints / notes")
            } footer: {
                Text(
                    "Optional. Injuries or exercises to avoid. The AI coach treats this as a hard constraint.",
                )
                .font(.system(size: 12))
                .foregroundColor(.appMuted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBg)
    }

    @ViewBuilder
    private var bodyWeightRow: some View {
        Button {
            showBodyWeightSheet = true
        } label: {
            HStack {
                Text(currentWeightDisplay)
                    .foregroundColor(.white)
                Spacer()
                Text("Log / view history")
                    .font(.system(size: 13))
                    .foregroundColor(.appAccent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appMuted)
            }
        }
        .listRowBackground(Color.appCard)
    }

    /// The latest weight expressed in the user's preferred unit, or a
    /// "No weight logged" placeholder. Inline SwiftData fetch rather
    /// than a @Query property because computed properties can't host
    /// property wrappers; volume is always a handful of rows so the
    /// fetch cost is negligible and happens only on body re-render.
    private var currentWeightDisplay: String {
        let descriptor = FetchDescriptor<BodyWeightEntry>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.measuredAt, order: .reverse)],
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        guard let latest = rows.first else { return "No weight logged" }
        let value = usesKg
            ? latest.weightKg
            : latest.weightKg * 2.20462
        let rounded = (value * 10).rounded() / 10
        return "\(formattedNumber(rounded)) \(usesKg ? "kg" : "lbs")"
    }

    @ViewBuilder
    private var unitPicker: some View {
        Picker("Units", selection: $preferredUnit) {
            Text("Pounds (lbs)").tag("lbs")
            Text("Kilograms (kg)").tag("kg")
        }
        .foregroundColor(.white)
        .listRowBackground(Color.appCard)
    }

    @ViewBuilder
    private var birthYearField: some View {
        LabeledContent("Birth year") {
            TextField("", text: $birthYearText, prompt: Text("e.g. 1990").foregroundColor(.appMuted))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.white)
        }
        .listRowBackground(Color.appCard)
    }

    @ViewBuilder
    private var sexPicker: some View {
        Picker("Sex", selection: $sex) {
            Text("Select…").tag("")
            Text("Male").tag("male")
            Text("Female").tag("female")
            Text("Other").tag("other")
            Text("Prefer not to say").tag("prefer_not_to_say")
        }
        .foregroundColor(.white)
        .listRowBackground(Color.appCard)
    }

    @ViewBuilder
    private var heightField: some View {
        LabeledContent(usesKg ? "Height (cm)" : "Height (in)") {
            TextField(
                "",
                text: $heightText,
                prompt: Text(usesKg ? "e.g. 178" : "e.g. 70")
                    .foregroundColor(.appMuted),
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .foregroundColor(.white)
        }
        .listRowBackground(Color.appCard)
    }

    @ViewBuilder
    private var experiencePicker: some View {
        Picker("Experience", selection: $experienceLevel) {
            Text("Select…").tag("")
            Text("Novice").tag("novice")
            Text("Intermediate").tag("intermediate")
            Text("Advanced").tag("advanced")
        }
        .foregroundColor(.white)
        .listRowBackground(Color.appCard)
    }

    @ViewBuilder
    private var goalPicker: some View {
        Picker("Primary goal", selection: $primaryGoal) {
            Text("Select…").tag("")
            Text("Strength").tag("strength")
            Text("Hypertrophy").tag("hypertrophy")
            Text("Fat loss").tag("fat_loss")
            Text("General fitness").tag("general")
            Text("Powerlifting").tag("powerlifting")
        }
        .foregroundColor(.white)
        .listRowBackground(Color.appCard)
    }

    @ViewBuilder
    private var equipmentPicker: some View {
        Picker("Equipment", selection: $equipmentAccess) {
            Text("Select…").tag("")
            Text("Full gym").tag("full_gym")
            Text("Home gym").tag("home_gym")
            Text("Bodyweight only").tag("bodyweight")
            Text("Limited").tag("limited")
        }
        .foregroundColor(.white)
        .listRowBackground(Color.appCard)
    }

    @ViewBuilder
    private var trainingDaysField: some View {
        LabeledContent("Days / week") {
            TextField(
                "",
                text: $trainingDaysText,
                prompt: Text("1–7").foregroundColor(.appMuted),
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .foregroundColor(.white)
        }
        .listRowBackground(Color.appCard)
    }

    @ViewBuilder
    private var notesField: some View {
        // Multi-line text editor. Capped to 500 chars server-side but
        // not enforced in the UI -- server will 400 if exceeded; we
        // could add a counter later.
        TextField(
            "",
            text: $notes,
            prompt: Text(
                "Injuries, exercises to avoid, anything the coach should respect",
            ).foregroundColor(.appMuted),
            axis: .vertical,
        )
        .lineLimit(3...6)
        .foregroundColor(.white)
        .listRowBackground(Color.appCard)
    }

    // MARK: - Load / save

    private func loadFromModel() {
        guard let p = currentProfile else {
            // No profile row yet -- form starts empty. Initialize the
            // unit picker from @AppStorage so the picker isn't fighting
            // the rest of the app's current unit preference, and save()
            // creates a row if the user changes anything.
            preferredUnit = legacyUnitStore
            return
        }
        birthYearText = p.birthYear.map(String.init) ?? ""
        // Height in cm canonical; convert to inches for display when
        // unit is imperial.
        if let cm = p.heightCm {
            let display = (p.preferredUnit == "kg") ? cm : cm / 2.54
            heightText = formattedNumber((display * 10).rounded() / 10)
        }
        trainingDaysText = p.trainingDaysPerWeek.map(String.init) ?? ""
        notes = p.notes ?? ""
        sex = p.sex ?? ""
        experienceLevel = p.experienceLevel ?? ""
        primaryGoal = p.primaryGoal ?? ""
        equipmentAccess = p.equipmentAccess ?? ""
        preferredUnit = p.preferredUnit ?? legacyUnitStore

        // If the profile was synced from the server with a unit the
        // rest of the app doesn't know about yet, propagate to
        // @AppStorage. Cheapest place to put this reconciliation --
        // every unit read either comes through here or doesn't need
        // to be fresh-from-server.
        if let unit = p.preferredUnit, unit != legacyUnitStore {
            legacyUnitStore = unit
        }
    }

    private func save() {
        // Parse + validate the free-text fields. Keep silent on
        // obviously-bogus inputs rather than trying to flag each one
        // -- too noisy for a profile form.
        let birthYear: Int? = {
            guard let v = Int(birthYearText.trimmingCharacters(in: .whitespaces)) else { return nil }
            return (1900...2100).contains(v) ? v : nil
        }()
        let trainingDays: Int? = {
            guard let v = Int(trainingDaysText.trimmingCharacters(in: .whitespaces)) else { return nil }
            return (1...7).contains(v) ? v : nil
        }()
        let heightCm: Double? = {
            let trimmed = heightText.trimmingCharacters(in: .whitespaces)
            guard let v = Double(trimmed) else { return nil }
            let cm = usesKg ? v : v * 2.54
            return (50...300).contains(cm) ? cm : nil
        }()
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNotes = trimmedNotes.isEmpty ? nil : String(trimmedNotes.prefix(500))

        do {
            let profile = currentProfile ?? {
                let p = UserProfile()
                modelContext.insert(p)
                return p
            }()

            profile.birthYear = birthYear
            profile.sex = sex.isEmpty ? nil : sex
            profile.heightCm = heightCm
            profile.experienceLevel = experienceLevel.isEmpty ? nil : experienceLevel
            profile.trainingDaysPerWeek = trainingDays
            profile.primaryGoal = primaryGoal.isEmpty ? nil : primaryGoal
            profile.equipmentAccess = equipmentAccess.isEmpty ? nil : equipmentAccess
            profile.preferredUnit = preferredUnit
            profile.notes = finalNotes
            profile.markDirty()

            try modelContext.save()
            // Write-through to @AppStorage so the rest of the app
            // (HomeView, WorkoutView, CoachView, LocalCoach) picks up
            // the new unit immediately without needing to reach into
            // the UserProfile model. This is the only write path from
            // UI -> AppStorage; the other direction (server pull
            // changes preferredUnit) is handled in loadFromModel.
            legacyUnitStore = preferredUnit

            SyncEngine.shared?.scheduleSync()
            dismiss()
        } catch {
            saveError = "\(error)"
        }
    }

    /// Trim trailing ".0" for whole-number display, keep one decimal
    /// place otherwise. Avoids "178.0 cm" / "70.0 in" reading as
    /// clumsy.
    private func formattedNumber(_ v: Double) -> String {
        if v == v.rounded() {
            return String(Int(v))
        }
        return String(format: "%.1f", v)
    }
}

// MARK: - Preview

#Preview {
    ProfileView()
        .modelContainer(for: [UserProfile.self, BodyWeightEntry.self], inMemory: true)
}
