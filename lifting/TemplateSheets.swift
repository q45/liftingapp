// TemplateSheets.swift
// Two sheets that make up the template user journey:
//
//   FinishWorkoutSheet  -- shown immediately after tapping Finish on a
//                          workout with at least one logged set. Offers
//                          to save the just-completed session as a
//                          reusable template. Skipping is a first-class
//                          option (no nagging).
//
//   TemplatePickerSheet -- shown from the Workout tab's empty state
//                          when the user wants to start a new session
//                          pre-loaded with a saved template's exercises.
//                          Supports swipe-to-delete; tap selects.
//
// Both are kept in one file so the small pieces (summary row builders,
// shared styles) stay close and we don't scatter template UI across
// five files for one feature.

import SwiftUI
import SwiftData

// MARK: - FinishWorkoutSheet

struct FinishWorkoutSheet: View {
    /// The session that was just finished. Used to summarize and to
    /// seed the template if the user opts in.
    let session: WorkoutSession
    let unit: String
    /// Called with the template name the user typed. Nil means "skip".
    let onDone: (String?) -> Void
    /// Called when the user taps "Actually, continue this workout".
    /// Provides an immediate undo for accidental Finish taps -- the
    /// parent is expected to call WorkoutManager.resume(session) and
    /// then clear whatever state was gating this sheet.
    /// Optional: supply nil if you want to keep the old sheet (no
    /// resume affordance).
    var onResume: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var nameFieldFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty }

    var body: some View {
        ZStack {
            Color(red: 0.086, green: 0.086, blue: 0.086).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                dragHandle
                header
                summaryBlock
                namePrompt
                Spacer(minLength: 12)
                actionButtons
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(false)
    }

    // MARK: Subviews

    @ViewBuilder
    private var dragHandle: some View {
        Capsule()
            .fill(Color.appBorder)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 18)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.appAccent)
                Text("WORKOUT SAVED")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appAccent)
                    .kerning(1)
            }
            Text("Save as template?")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
            Text("Reuse this exercise list for future sessions.")
                .font(.system(size: 13))
                .foregroundColor(.appMuted)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var summaryBlock: some View {
        let totalSets = session.totalSets
        let totalVolume = Int(session.totalVolume)
        let duration = session.durationString
        HStack(spacing: 0) {
            summaryCell(label: "EXERCISES", value: "\(session.liveExercises.count)")
            Divider().background(Color.appBorder).frame(width: 1, height: 40)
            summaryCell(label: "SETS", value: "\(totalSets)")
            Divider().background(Color.appBorder).frame(width: 1, height: 40)
            summaryCell(label: "VOLUME", value: "\(totalVolume)", sub: unit)
            Divider().background(Color.appBorder).frame(width: 1, height: 40)
            summaryCell(label: "TIME", value: duration)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func summaryCell(label: String, value: String, sub: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.6)
            Text(value)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            if let sub {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundColor(.appMuted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var namePrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEMPLATE NAME")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.8)
            TextField("e.g. Push Day A", text: $name)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(false)
                .focused($nameFieldFocused)
                .foregroundColor(.white)
                .tint(.appAccent)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color.appCard2)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
                .submitLabel(.done)
                .onSubmit(saveIfValid)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button("Save Template") { saveIfValid() }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canSave)

            Button("Skip") {
                onDone(nil)
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle())

            // Undo affordance for the "I tapped Finish by accident"
            // case. Sits below the primary actions so a user who meant
            // to finish doesn't click it by habit, but visible enough
            // that someone realizing their mistake sees it immediately.
            if let onResume {
                Button {
                    onResume()
                    dismiss()
                } label: {
                    Label("Actually, continue this workout", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.appMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .accessibilityLabel("Resume this workout")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func saveIfValid() {
        guard canSave else { return }
        onDone(trimmedName)
        dismiss()
    }
}

// MARK: - TemplatePickerSheet

struct TemplatePickerSheet: View {
    /// Called when the user picks a template to start a workout from.
    let onPick: (WorkoutTemplate) -> Void
    /// Called when the user swipes to delete a template.
    let onDelete: (WorkoutTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    // Query templates directly rather than taking them as a parameter
    // so the list auto-refreshes when SyncEngine pulls new ones in
    // the background.
    @Query(
        filter: #Predicate<WorkoutTemplate> { $0.deletedAt == nil },
        sort: \WorkoutTemplate.order,
    ) private var templates: [WorkoutTemplate]

    /// Drives the create/edit sheet. Nil = no editor open; .new =
    /// create-mode editor; .edit(t) = edit-mode editor for template `t`.
    @State private var editorMode: EditorMode? = nil

    private enum EditorMode: Identifiable {
        case new
        case edit(WorkoutTemplate)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let t): return "edit-\(t.id)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                if templates.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Start from Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.appMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Plain "+" button opens the editor in create
                    // mode. Sits next to the title so it's reachable
                    // whether the list is empty or full.
                    Button {
                        editorMode = .new
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.appAccent)
                            .bold()
                    }
                    .accessibilityLabel("New template")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .sheet(item: $editorMode) { mode in
            switch mode {
            case .new:
                TemplateEditorView(editing: nil)
            case .edit(let t):
                TemplateEditorView(editing: t)
            }
        }
    }

    // MARK: Subviews

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundColor(.appMuted)
                .padding(.bottom, 4)
            Text("No Templates Yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text("Build a routine ahead of time, or save a finished workout as a template to reuse it next time.")
                .font(.system(size: 13))
                .foregroundColor(.appMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                editorMode = .new
            } label: {
                Label("Create Template", systemImage: "plus")
            }
            .buttonStyle(AccentButtonStyle())
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var list: some View {
        // Plain List with custom row cells so swipe-to-delete and
        // swipe-to-edit Just Work without us reimplementing gesture
        // handling. scrollContentBackground keeps the app's dark theme
        // instead of iOS's default grouped-gray.
        List {
            ForEach(templates, id: \.id) { template in
                Button {
                    onPick(template)
                    dismiss()
                } label: {
                    TemplateRow(template: template)
                }
                .listRowBackground(Color.appCard)
                .listRowSeparatorTint(Color.appBorder)
                // Two trailing swipe actions: destructive Delete (full
                // swipe) plus a non-destructive Edit. Edit sits to the
                // left of Delete so a full swipe doesn't accidentally
                // open the editor when the user meant to delete.
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onDelete(template)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editorMode = .edit(template)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.appAccent)
                }
                // Long-press menu for users who don't think to swipe.
                // Same actions, alternate discovery path.
                .contextMenu {
                    Button {
                        editorMode = .edit(template)
                    } label: {
                        Label("Edit Template", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete(template)
                    } label: {
                        Label("Delete Template", systemImage: "trash")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

private struct TemplateRow: View {
    let template: WorkoutTemplate

    private var exercises: [TemplateExercise] { template.orderedExercises }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.appMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    /// "4 exercises · Bench Press, Incline Bench, Dumbbell Fly, Tricep Pushdown"
    /// Truncated with ... if longer than the line fits.
    private var subtitle: String {
        let count = exercises.count
        if count == 0 { return "Empty template" }
        let names = exercises.map(\.name).joined(separator: ", ")
        return "\(count) exercise\(count == 1 ? "" : "s") · \(names)"
    }
}
