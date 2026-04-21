// AuthManager.swift
// Session lifecycle: holds the server-issued JWT, surfaces signed-in
// state to SwiftUI, handles the token-exchange handshake.
//
// # What lives here
//
// - The JWT (session access token), read from and written to the
//   Keychain. We never put it in UserDefaults / AppStorage -- those are
//   unencrypted plists, and a session token is a bearer credential.
// - The authenticated user's server-assigned UUID. Views use this to
//   partition @AppStorage keys per user (e.g. drafts, goal preferences)
//   without the data "leaking" across account switches on one device.
// - The expiry date. iOS can renew proactively by re-auth'ing with the
//   identity provider before the current token expires, avoiding a
//   noisy 401 round-trip on a cold start.
//
// # What does NOT live here (yet)
//
// - The Apple / Google sign-in flow UI. That's Phase 2 (a SignInSheet
//   view that calls `AuthManager.signInWithApple(...)`). Until then this
//   file is essentially a Keychain-backed state holder + a method for
//   Phase 2 to call once it has an identity token.
// - StoreKit / subscription status. That's Phase 3.

import Foundation
import Observation

@MainActor
@Observable
final class AuthManager {
    /// Singleton instance wired up from liftingApp.swift on launch.
    /// Separate from `SyncEngine.shared` so tests can swap it out.
    static let shared = AuthManager()

    /// True once a JWT exists on this device (expiry not checked -- a
    /// soft-expired token is still "signed in" for UI purposes; the
    /// server will return 401 and we'll silently re-auth).
    private(set) var isSignedIn: Bool

    /// Server user UUID associated with the stored token. Nil when
    /// signed out.
    private(set) var userID: UUID?

    /// Cached access token. Private so views are forced through
    /// `authorizedClient()` instead of splicing the header themselves.
    private var accessToken: String?

    /// Server-reported expiry. Used to decide whether to proactively
    /// refresh when the app comes to foreground.
    private(set) var expiresAt: Date?

    init() {
        // Compute every stored-property value from locals first, then
        // assign. @Observable rewrites property accessors so reading
        // `self.userID` mid-init (before every other stored property is
        // initialized) fails to compile.
        let token = KeychainHelper.read(key: KeychainHelper.authTokenKey)
        let userIDString = KeychainHelper.read(key: KeychainHelper.authUserIDKey)
        let expiryString = KeychainHelper.read(key: KeychainHelper.authExpiresAtKey)
        let parsedUserID = userIDString.flatMap { UUID(uuidString: $0) }
        let parsedExpiry = expiryString.flatMap { ISO8601DateFormatter().date(from: $0) }

        self.accessToken = token
        self.userID = parsedUserID
        self.expiresAt = parsedExpiry
        self.isSignedIn = token != nil && parsedUserID != nil
    }

    // MARK: - Public surface

    /// Build an API client pre-configured with the current session.
    /// Use this anywhere the app needs to call the server; never
    /// construct a `LiftingAPIClient` by hand, or you'll miss the
    /// Bearer header and hit 401s in prod.
    func authorizedClient() -> LiftingAPIClient {
        LiftingAPIClient(
            baseURL: LiftingAPIClient.defaultBaseURL,
            apiKey: KeychainHelper.read(key: KeychainHelper.apiKeyKey),
            authToken: accessToken,
        )
    }

    /// Exchange an Apple identity token for a session JWT. Called from
    /// the Phase-2 sign-in sheet once ASAuthorization returns credentials.
    /// Returns the authenticated user on success; throws on network /
    /// server error.
    @discardableResult
    func signInWithApple(identityToken: String) async throws -> AuthUserDTO {
        let client = LiftingAPIClient(baseURL: LiftingAPIClient.defaultBaseURL)
        let response = try await client.exchangeAppleIdentityToken(identityToken)
        persist(response)
        return response.user
    }

    /// Exchange a Google ID token for a session JWT. Google SDK's
    /// `GIDGoogleUser.idToken.tokenString` is the value to pass.
    @discardableResult
    func signInWithGoogle(identityToken: String) async throws -> AuthUserDTO {
        let client = LiftingAPIClient(baseURL: LiftingAPIClient.defaultBaseURL)
        let response = try await client.exchangeGoogleIdentityToken(identityToken)
        persist(response)
        return response.user
    }

    /// Wipe session state locally. We fire a best-effort /auth/signout
    /// but don't block on it -- the client is the source of truth for
    /// "am I signed in right now" and we always want the UI to update
    /// even if the server is unreachable.
    func signOut() {
        if let accessToken, !accessToken.isEmpty {
            let client = LiftingAPIClient(
                baseURL: LiftingAPIClient.defaultBaseURL,
                authToken: accessToken,
            )
            Task.detached { try? await client.signOut() }
        }
        clear()
    }

    // MARK: - Internals

    private func persist(_ response: AuthExchangeResponseDTO) {
        KeychainHelper.write(response.accessToken, forKey: KeychainHelper.authTokenKey)
        KeychainHelper.write(
            response.user.id.uuidString,
            forKey: KeychainHelper.authUserIDKey,
        )
        KeychainHelper.write(
            ISO8601DateFormatter().string(from: response.expiresAt),
            forKey: KeychainHelper.authExpiresAtKey,
        )
        accessToken = response.accessToken
        userID = response.user.id
        expiresAt = response.expiresAt
        isSignedIn = true
    }

    private func clear() {
        KeychainHelper.delete(key: KeychainHelper.authTokenKey)
        KeychainHelper.delete(key: KeychainHelper.authUserIDKey)
        KeychainHelper.delete(key: KeychainHelper.authExpiresAtKey)
        accessToken = nil
        userID = nil
        expiresAt = nil
        isSignedIn = false
    }
}
