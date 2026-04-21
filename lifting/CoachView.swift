// CoachView.swift
// AI Coach — server-proxied recommendations.
//
// The iOS app no longer talks to Anthropic directly. It calls
// `POST /coach/recommendations` on the lifting server, which pulls the
// user's recent completed sessions from Postgres, builds a prompt, calls
// Claude, validates the JSON response with Zod, caches it, and returns
// a structured payload.
//
// Sensitive config (shared X-API-Key for the server, optional custom
// server URL) lives in the iOS Keychain via KeychainHelper, NOT in
// @AppStorage / UserDefaults. The Anthropic API key never touches the
// device -- it lives in server/.env.

import SwiftUI
import SwiftData

struct CoachView: View {
    @Query(sort: \WorkoutSession.endTime) private var allSessions: [WorkoutSession]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("userGoal")   private var goal = "stronger"
    @AppStorage("weightUnit") private var unit = "lbs"

    // Unified outcome type: either the server responded (optionally
    // cached) or we fell back to LocalCoach. The view renders the
    // same shape either way, with a source badge distinguishing them.
    @State private var outcome: WorkoutCoachOutcome? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showSettingsSheet = false
    @State private var showProfileSheet = false
    @State private var hasAPIKey: Bool = KeychainHelper.read(key: KeychainHelper.apiKeyKey) != nil

    private var completedSessions: [WorkoutSession] {
        allSessions.filter { $0.isLive && $0.isCompleted }
    }

    private var goalObj: GoalOption? { goalOptions.first { $0.id == goal } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        goalPicker
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)

                        ctaBlock
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)

                        if isLoading {
                            HStack(spacing: 10) {
                                ProgressView().tint(.appAccent)
                                Text("Claude is analyzing your training data…")
                                    .font(.system(size: 13))
                                    .foregroundColor(.appMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 16)
                        }

                        if let err = errorMessage {
                            errorBanner(err)
                        }

                        if let outcome {
                            recommendationsBlock(outcome)
                                .padding(.horizontal, 20)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("AI Coach")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // Two distinct concerns deserve two distinct buttons:
                // the gear holds connection config (server URL, API
                // key, Keychain-backed); the person icon opens the
                // athlete profile that the AI coach reads from.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showProfileSheet = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .foregroundColor(.appMuted)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.appMuted)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet, onDismiss: {
            hasAPIKey = KeychainHelper.read(key: KeychainHelper.apiKeyKey) != nil
        }) {
            CoachSettingsSheet()
        }
        .sheet(isPresented: $showProfileSheet) {
            ProfileView()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var goalPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "My Goal")
            ForEach(goalOptions) { g in
                Button {
                    goal = g.id
                    outcome = nil
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .stroke(goal == g.id ? Color.appAccent : Color.appMuted, lineWidth: 2)
                                .frame(width: 18, height: 18)
                            if goal == g.id {
                                Circle()
                                    .fill(Color.appAccent)
                                    .frame(width: 10, height: 10)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.label)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                            Text(g.desc)
                                .font(.system(size: 12))
                                .foregroundColor(.appMuted)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(goal == g.id ? Color.appAccent.opacity(0.12) : Color.appCard)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(goal == g.id ? Color.appAccent : Color.appBorder, lineWidth: 1.5),
                    )
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var ctaBlock: some View {
        VStack(spacing: 12) {
            if completedSessions.isEmpty {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.appMuted)
                    Text("Log at least one workout to get AI recommendations")
                        .font(.system(size: 14))
                        .foregroundColor(.appMuted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appCard)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
            } else {
                Button(isLoading ? "Analyzing your lifts…" : "Get Recommendations →") {
                    Task { await fetchRecommendations(refresh: false) }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(isLoading)

                // Regenerate button: shown for any non-nil outcome so
                // users can force a fresh call regardless of whether the
                // current one is cached, offline, or freshly generated.
                // Useful when they've just updated their profile and
                // want the coach to re-weigh its advice.
                if outcome != nil {
                    Button {
                        Task { await fetchRecommendations(refresh: true) }
                    } label: {
                        Label(
                            regenerateLabel(for: outcome),
                            systemImage: "arrow.clockwise",
                        )
                        .font(.system(size: 13))
                        .foregroundColor(.appAccent)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.appRed)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.appRed)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appRed.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func recommendationsBlock(_ outcome: WorkoutCoachOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Your Plan")
                Spacer()
                sourceBadge(outcome.source)
            }
            // Summary card
            Text(outcome.summary)
                .font(.system(size: 14))
                .foregroundColor(.appMuted2)
                .lineSpacing(4)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appCard)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))

            ForEach(outcome.recommendations) { rec in
                RecommendationRow(rec: rec, unit: outcome.unit)
            }
        }
    }

    /// Small badge in the "Your Plan" header showing where the
    /// recommendation came from. Mirrors the badge in ExerciseCoachSheet
    /// so the visual language stays consistent across coach surfaces.
    @ViewBuilder
    private func sourceBadge(_ source: WorkoutCoachOutcome.Source) -> some View {
        switch source {
        case .server(let cached):
            if cached {
                Label("Cached", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appMuted)
            } else {
                EmptyView()
            }
        case .offline:
            Label("Offline suggestion", systemImage: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appMuted)
        }
    }

    /// Regenerate button label adapts to the current outcome's source.
    /// When offline, "bypass cache" is a lie (there's no server cache);
    /// "Retry with Claude" communicates what the button actually does.
    private func regenerateLabel(for outcome: WorkoutCoachOutcome?) -> String {
        switch outcome?.source {
        case .offline: return "Retry with Claude"
        default:       return "Regenerate (bypass cache)"
        }
    }

    // MARK: - Fetch

    /// Try the server first; on any failure (offline, 5xx, Anthropic
    /// outage, missing API key server-side), fall through to the local
    /// rule-based coach so the user still gets a usable set of
    /// recommendations. Matches the behavior ExerciseCoachSheet already
    /// has for per-exercise requests.
    ///
    /// We deliberately don't surface the network error to the UI when
    /// the fallback succeeds -- the "Offline suggestion" badge already
    /// communicates what's going on, and a red error banner above a
    /// perfectly usable recommendation would just be noise.
    private func fetchRecommendations(refresh: Bool) async {
        isLoading = true
        errorMessage = nil

        do {
            let resp = try await ClaudeService.fetchRecommendations(
                goal: goal,
                unit: unit,
                refresh: refresh,
            )
            outcome = WorkoutCoachOutcome(serverResponse: resp)
        } catch {
            print("⚠️ Coach server call failed, falling back to local: \(error)")
            outcome = LocalCoach.recommendWorkout(
                goal: goal,
                unit: unit,
                context: modelContext,
            )
        }
        isLoading = false
    }
}

// MARK: - Single recommendation row

struct RecommendationRow: View {
    let rec: CoachRecommendationDTO
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rec.exerciseName)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.appAccent)
            HStack(spacing: 16) {
                metric(label: "Weight", value: "\(weightString) \(unit)")
                metric(label: "Sets", value: "\(rec.sets)")
                metric(label: "Reps", value: "\(rec.reps)")
            }
            Text(rec.tip)
                .font(.system(size: 13))
                .foregroundColor(.appMuted2)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.appMuted)
                .kerning(0.6)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var weightString: String {
        rec.weight.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(rec.weight))"
            : String(format: "%.1f", rec.weight)
    }
}

// MARK: - Settings sheet (server URL + API key, stored in Keychain)

struct CoachSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL: String = ""
    @State private var apiKey: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("These settings are stored in the iOS Keychain. The Anthropic API key lives only on the server — you never paste it here.")
                            .font(.system(size: 13))
                            .foregroundColor(.appMuted)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("SERVER URL")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.appMuted)
                                .kerning(0.8)
                            TextField("http://localhost:3000", text: $serverURL)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                                .foregroundColor(.white)
                                .tint(.appAccent)
                                .font(.system(size: 15, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
                                .background(Color.appCard2)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
                            Text("For a physical device on the same Wi-Fi, use your Mac's LAN IP (e.g. http://192.168.1.20:3000).")
                                .font(.system(size: 11))
                                .foregroundColor(.appMuted)
                        }
                        .padding(.horizontal, 20)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("SERVER API KEY (OPTIONAL)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.appMuted)
                                .kerning(0.8)
                            SecureField("Leave blank in dev", text: $apiKey)
                                .foregroundColor(.white)
                                .tint(.appAccent)
                                .font(.system(size: 15, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 13)
                                .background(Color.appCard2)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
                            Text("Must match server's API_KEY environment variable if set. Only used to authenticate this client against your server — has nothing to do with Claude.")
                                .font(.system(size: 11))
                                .foregroundColor(.appMuted)
                        }
                        .padding(.horizontal, 20)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("Coach Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.appMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        KeychainHelper.write(serverURL, forKey: KeychainHelper.serverURLKey)
                        KeychainHelper.write(apiKey, forKey: KeychainHelper.apiKeyKey)
                        dismiss()
                    }
                    .foregroundColor(.appAccent)
                }
            }
            .onAppear {
                serverURL = KeychainHelper.read(key: KeychainHelper.serverURLKey) ?? ""
                apiKey = KeychainHelper.read(key: KeychainHelper.apiKeyKey) ?? ""
            }
        }
        .preferredColorScheme(.dark)
    }
}
