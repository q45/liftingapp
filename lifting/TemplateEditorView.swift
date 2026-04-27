// TemplateEditorView.swift
// Build or edit a workout template before doing the workout.
//
// One screen, two modes:
//
//   Create mode  (`editing: nil`):
//     - Sheet opens empty.
//     - Name + pending exercises live in @State; nothing is persisted
//       until the user taps "Create Template". Cancel just dismisses
//       and discards the draft. This matches user expectation that
//       "I'm building something new -- I can bail freely".
//
//   Edit mode  (`editing: someTemplate`):
//     - Reads the existing template directly. Every change (rename,
//       add exercise, reorder, delete) persists immediately through
//       WorkoutManager and propagates via SyncEngine.
//     - "Done" just dismisses; there's nothing to commit. Matches
//       Notes / Reminders semantics where edits are live.
//
// The two modes look identical to the user. The asymmetry is internal.

import SwiftUI
import SwiftData

struct TemplateEditorView: View {
    /// nil = create new; non-nil = edit this template in place.
    let editing: WorkoutTemplate?

    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.dismiss) private var dismiss

    /// Working name. In edit mode initialized from the template; in
    /// create mode starts blank. Committed on field blur (edit) or on
    /// "Create Template" (create).
    @State private var name: String = ""

    /// Create-mode-only: pending exercises the user has added before
    /// the template exists. Tuple-of-struct so we can move/reorder
    /// without dealing with SwiftData identity. Empty in edit mode.
    @State private var pending: [PendingExercise] = []

    /// Backing for the inline "Add Exercise" picker.
    @State private var showExercisePicker = false

    /// Triggers an alert + bails out when create-mode commit fails
    /// (e.g. the WorkoutManager refuses an empty name -- shouldn't
    /// happen because the button is disabled, but defensive).
    @State private var saveError: String?

    @FocusState private var nameFocused: Bool

    private var isEditing: Bool { editing != nil }

    /// Trimmed name -- the gate for whether Save / Create is enabled
    /// and what we actually persist.
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Number of exercises currently in the template (live or pending).
    /// Drives the subtitle and the "save disabled" rule.
    private var exerciseCount: Int {
        if let editing { return editing.orderedExercises.count }
        return pending.count
    }

    /// Save / Create action is gated on a non-empty name AND at least
    /// one exercise. Allowing zero-exercise templates would let users
    /// save a dud they'd then have to clean up later; cheaper to gate.
    private var canCommit: Bool {
        !trimmedName.isEmpty && exerciseCount > 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                form
            }
            .navigationTitle(isEditing ? "Edit Template" : "New Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? "Done" : "Cancel") {
                        // Edit mode: changes already saved. Create mode:
                        // pending state is dropped on dismiss.
                        if isEditing {
                            commitNameIfChanged()
                        }
                        dismiss()
                    }
                    .foregroundColor(.appMuted)
                }
                if !isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { commitCreate() }
                            .foregroundColor(canCommit ? .appAccent : .appMuted)
                            .bold()
                            .disabled(!canCommit)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerView { exName, category in
                addExercise(name: exName, category: category)
                showExercisePicker = false
            }
        }
        .onAppear(perform: loadInitialState)
        .alert("Couldn't save template", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } },
        )) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        VStack(spacing: 0) {
            nameField
            exerciseListSection
            addExerciseButton
        }
    }

    @ViewBuilder
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEMPLATE NAME")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.8)
            TextField(
                "",
                text: $name,
                prompt: Text("e.g. Push Day A").foregroundColor(.appMuted),
            )
            .textInputAutocapitalization(.words)
            .disableAutocorrection(false)
            .focused($nameFocused)
            .foregroundColor(.white)
            .tint(.appAccent)
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color.appCard2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
            .submitLabel(.done)
            .onSubmit {
                if isEditing { commitNameIfChanged() }
                nameFocused = false
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var exerciseListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EXERCISES (\(exerciseCount))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appMuted)
                    .kerning(0.8)
                Spacer()
                if exerciseCount > 1 {
                    // Tiny hint that drag-to-reorder is available.
                    // Keep it muted so it doesn't compete with content.
                    Text("Hold + drag to reorder")
                        .font(.system(size: 11))
                        .foregroundColor(.appMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if exerciseCount == 0 {
                emptyExerciseHint
                    .padding(.horizontal, 20)
            } else {
                exerciseList
            }
        }
    }

    @ViewBuilder
    private var emptyExerciseHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No exercises yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text("Add the exercises this routine should include. You can reorder and remove them anytime.")
                .font(.system(size: 12))
                .foregroundColor(.appMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var exerciseList: some View {
        // SwiftUI's drag-to-reorder + swipe-to-delete come for free
        // inside a List, so we use one despite the rest of the app
        // mostly avoiding lists. scrollContentBackground hides the
        // default grouped-gray to let our dark theme show through.
        List {
            if let editing {
                ForEach(editing.orderedExercises, id: \.id) { ex in
                    exerciseRow(name: ex.name, category: ex.category)
                        .listRowBackground(Color.appCard)
                        .listRowSeparatorTint(Color.appBorder)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                workoutManager.removeExerciseFromTemplate(ex)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
                .onMove { source, destination in
                    // SwiftUI's `Array.move(fromOffsets:toOffset:)`
                    // lives in this file (we import SwiftUI here);
                    // we apply it then hand the manager the final
                    // ordered list. Keeps Models.swift free of any
                    // SwiftUI dependency.
                    var live = editing.orderedExercises
                    live.move(fromOffsets: source, toOffset: destination)
                    workoutManager.reorderTemplateExercises(
                        editing,
                        ordered: live,
                    )
                }
            } else {
                ForEach(pending) { p in
                    exerciseRow(name: p.name, category: p.category)
                        .listRowBackground(Color.appCard)
                        .listRowSeparatorTint(Color.appBorder)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                pending.removeAll { $0.id == p.id }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
                .onMove { source, destination in
                    pending.move(fromOffsets: source, toOffset: destination)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBg)
        .frame(minHeight: 60)
    }

    @ViewBuilder
    private func exerciseRow(name: String, category: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(categoryColor(category))
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            Spacer()
            Text(category)
                .font(.system(size: 11))
                .foregroundColor(.appMuted)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var addExerciseButton: some View {
        Button { showExercisePicker = true } label: {
            Label("Add Exercise", systemImage: "plus")
        }
        .buttonStyle(SecondaryButtonStyle())
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    // MARK: - State helpers

    private func loadInitialState() {
        if let editing {
            name = editing.name
        } else {
            // Auto-focus the name field in create mode so users can
            // type a name immediately. Skip in edit mode -- the user
            // is here to tweak something else.
            DispatchQueue.main.async {
                nameFocused = true
            }
        }
    }

    /// Add a new exercise either to the live template (edit mode) or
    /// to the pending in-memory list (create mode). Same UX either
    /// way; the source-of-truth swap is internal.
    private func addExercise(name exName: String, category: String) {
        let trimmed = exName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let editing {
            workoutManager.addExerciseToTemplate(
                editing,
                name: trimmed,
                category: category,
            )
        } else {
            pending.append(
                PendingExercise(name: String(trimmed.prefix(60)), category: category),
            )
        }
    }

    /// In edit mode, push the typed name back into the model when the
    /// field loses focus or the user dismisses. No-op when unchanged
    /// (renameTemplate has its own guard but we save a function call).
    private func commitNameIfChanged() {
        guard let editing else { return }
        guard !trimmedName.isEmpty, trimmedName != editing.name else { return }
        workoutManager.renameTemplate(editing, to: trimmedName)
    }

    /// Create-mode commit: insert template + each pending exercise in
    /// order, then dismiss. WorkoutManager's helpers handle markDirty
    /// + sync, so the new template propagates to the server on the
    /// next sync round-trip.
    private func commitCreate() {
        guard !isEditing, canCommit else { return }
        guard let template = workoutManager.createEmptyTemplate(name: trimmedName) else {
            saveError = "Couldn't create the template. Check the name and try again."
            return
        }
        for p in pending {
            workoutManager.addExerciseToTemplate(
                template,
                name: p.name,
                category: p.category,
            )
        }
        dismiss()
    }
}

// MARK: - Pending exercise (create mode only)

/// In-memory representation of a row the user has added before the
/// template itself exists. Identifiable so the ForEach + swipe + move
/// modifiers can track it without involving SwiftData.
private struct PendingExercise: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var category: String
}
