// ExercisePickerView.swift
// Sheet for browsing the exercise library or adding a custom exercise

import SwiftUI

struct ExercisePickerView: View {
    let onSelect: (String, String) -> Void

    @State private var query = ""
    @State private var selectedCategory = "All"
    @State private var customName = ""
    @State private var customCategory = "Chest"
    @Environment(\.dismiss) private var dismiss

    /// Drives focus on the custom-name TextField. Wrapping the whole
    /// custom section in a tap gesture that sets this to true
    /// sidesteps the usual "List row eats the first tap" bug that
    /// used to require 2-3 taps before the field would actually focus.
    @FocusState private var customNameFocused: Bool

    private var filtered: [ExerciseTemplate] {
        exerciseLibrary.filter { ex in
            (selectedCategory == "All" || ex.category == selectedCategory) &&
            (query.isEmpty || ex.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.appMuted)
                        TextField("Search exercises...", text: $query)
                            .foregroundColor(.white)
                            .tint(.appAccent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.appCard2)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    // Category chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories, id: \.self) { cat in
                                Button(cat) { selectedCategory = cat }
                                    .font(.system(size: 12, weight: selectedCategory == cat ? .bold : .medium))
                                    .foregroundColor(selectedCategory == cat ? .black : .appMuted2)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(selectedCategory == cat ? Color.appAccent : Color.appCard)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(selectedCategory == cat ? Color.appAccent : Color.appBorder, lineWidth: 1))
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 10)

                    Divider().background(Color.appBorder)

                    // Exercise list + custom section
                    List {
                        Section {
                            ForEach(filtered) { ex in
                                Button {
                                    onSelect(ex.name, ex.category)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Circle()
                                            .fill(categoryColor(ex.category))
                                            .frame(width: 10, height: 10)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ex.name)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundColor(.white)
                                            Text(ex.category)
                                                .font(.system(size: 11))
                                                .foregroundColor(.appMuted)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.appMuted)
                                    }
                                }
                                .listRowBackground(Color.appBg)
                                .listRowSeparatorTint(Color.appBorder)
                            }
                        }

                        // Custom exercise
                        //
                        // Lives inside the List so it scrolls with the
                        // rest of the picker, but `TextField` inside a
                        // List row has a long-standing focus bug where
                        // the first tap goes to the row and the second
                        // to the field. We work around it by:
                        //   1. Bumping the tap target to 52pt tall
                        //      (17pt font + 16pt*2 padding) so it's
                        //      well over the 44pt accessibility floor.
                        //   2. Driving focus via @FocusState so the
                        //      outer container can force-focus the
                        //      field on any tap within the section.
                        //   3. Adding a contentShape + tap gesture on
                        //      the whole VStack so taps on the label,
                        //      the field, or the background all land
                        //      the same way.
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionLabel(text: "Custom Exercise")
                                TextField(
                                    "",
                                    text: $customName,
                                    prompt: Text("Exercise name")
                                        .foregroundColor(.appMuted),
                                )
                                .font(.system(size: 17))
                                .foregroundColor(.white)
                                .tint(.appAccent)
                                .focused($customNameFocused)
                                .submitLabel(.done)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled(false)
                                .onSubmit(submitCustomIfValid)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .background(Color.appCard2)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
                                .contentShape(Rectangle())
                                .onTapGesture { customNameFocused = true }

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(["Chest","Back","Legs","Shoulders","Arms","Core"], id: \.self) { cat in
                                            Button(cat) { customCategory = cat }
                                                .font(.system(size: 12, weight: customCategory == cat ? .bold : .medium))
                                                .foregroundColor(customCategory == cat ? .black : .appMuted2)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 5)
                                                .background(customCategory == cat ? Color.appAccent : Color.appCard)
                                                .clipShape(Capsule())
                                                .overlay(Capsule().stroke(customCategory == cat ? Color.appAccent : Color.appBorder, lineWidth: 1))
                                        }
                                    }
                                }

                                if !customName.trimmingCharacters(in: .whitespaces).isEmpty {
                                    Button("Add \"\(customName.trimmingCharacters(in: .whitespaces))\"") {
                                        submitCustomIfValid()
                                    }
                                    .buttonStyle(AccentButtonStyle())
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color.appBg)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.appBg)
                }
            }
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.appMuted)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Confirm the custom exercise if the trimmed name is non-empty.
    /// Shared between the return-key submit path and the "Add ..." button
    /// so both code paths have identical semantics.
    private func submitCustomIfValid() {
        let trimmed = customName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSelect(trimmed, customCategory)
        dismiss()
    }
}
