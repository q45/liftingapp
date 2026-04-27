package com.wasatchcode.lifting.auth

import android.content.Context
import android.util.Log
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import com.wasatchcode.lifting.BuildConfig
import com.wasatchcode.lifting.data.dto.AuthResponseDTO
import com.wasatchcode.lifting.data.remote.ApiClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Owns auth state: whether the user is signed in, the session JWT,
 * and the wrapping `ApiClient` that will carry the JWT on every
 * request.
 *
 * Sign-in flow:
 *   1. Caller invokes `signInWithGoogle(activityContext)`. This
 *      shows the system Google account picker via the
 *      Credential Manager API.
 *   2. The user picks an account; Google issues a signed ID token.
 *   3. We POST the token to /auth/google. The server verifies it
 *      with Google's public keys, finds-or-creates the user, and
 *      returns a server JWT.
 *   4. We persist the JWT in EncryptedSharedPreferences and emit
 *      a new AuthState. The ApiClient's `bearer` lambda will read
 *      this token from now on.
 *
 * Why not the older GoogleSignInClient: that API is deprecated as
 * of mid-2024. Credential Manager is the future-proof path and is
 * required for new apps targeting modern Play Store policy.
 */
class AuthManager(
    context: Context,
    private val webClientId: String,
    private val apiClientFactory: (bearer: () -> String?) -> ApiClient,
) {
    private val secureStore = SecureStore(context)
    private val credentialManager = CredentialManager.create(context)

    private val _state = MutableStateFlow(loadInitialState())
    val state: StateFlow<AuthState> = _state.asStateFlow()

    /**
     * The shared API client, wired with a bearer-token closure that
     * always reads the latest token from this manager. The lambda
     * captures `_state` so token rotation propagates without
     * rebuilding the client.
     */
    val api: ApiClient = apiClientFactory { _state.value.accessToken }

    /**
     * Attempt Google Sign-In. Caller must pass an Activity context
     * (Credential Manager needs a window to host the account picker).
     *
     * Throws AuthException on user-visible failures (no Google
     * accounts on device, user cancelled, network error during the
     * exchange). Caller should display a Snackbar / inline error.
     */
    suspend fun signInWithGoogle(activityContext: Context): AuthResponseDTO {
        if (webClientId.isBlank()) {
            throw AuthException(
                "Google Web Client ID isn't configured. Set GOOGLE_WEB_CLIENT_ID in gradle.properties.",
            )
        }

        // Phase 1: ask Credential Manager for a Google ID token.
        // `setFilterByAuthorizedAccounts(false)` lets first-time
        // users pick any account; once they've signed in we can
        // pass true on subsequent attempts to skip the chooser.
        val googleIdOption = GetGoogleIdOption.Builder()
            .setServerClientId(webClientId)
            .setFilterByAuthorizedAccounts(false)
            .setAutoSelectEnabled(true)
            .build()
        val request = GetCredentialRequest.Builder()
            .addCredentialOption(googleIdOption)
            .build()

        val response = try {
            credentialManager.getCredential(activityContext, request)
        } catch (e: GetCredentialException) {
            Log.w(TAG, "Credential Manager flow failed", e)
            throw AuthException(
                e.message ?: "Couldn't sign in with Google. Try again.",
                cause = e,
            )
        }

        val cred = response.credential
        val idToken = when {
            cred is CustomCredential
                && cred.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL -> {
                try {
                    GoogleIdTokenCredential.createFrom(cred.data).idToken
                } catch (e: GoogleIdTokenParsingException) {
                    throw AuthException("Google returned an invalid token", cause = e)
                }
            }
            else -> throw AuthException(
                "Got an unexpected credential type back: ${cred.type}",
            )
        }

        // Phase 2: exchange with our server.
        val serverResponse = api.exchangeGoogleIdentityToken(idToken)

        // Persist + broadcast.
        with(secureStore) {
            putString(SecureStore.KEY_ACCESS_TOKEN, serverResponse.accessToken)
            putString(SecureStore.KEY_TOKEN_EXPIRES_AT, serverResponse.expiresAt)
            putString(SecureStore.KEY_USER_ID, serverResponse.user.id)
            putString(SecureStore.KEY_USER_EMAIL, serverResponse.user.email)
            putString(SecureStore.KEY_USER_NAME, serverResponse.user.name)
        }
        _state.value = AuthState(
            accessToken = serverResponse.accessToken,
            expiresAt = serverResponse.expiresAt,
            userID = serverResponse.user.id,
            email = serverResponse.user.email,
            name = serverResponse.user.name,
        )
        return serverResponse
    }

    /**
     * Clear the local session. Tells the server (best-effort) so we
     * can later add audit logging / push-token cleanup, but never
     * blocks on it -- if the network call fails the client is still
     * signed out locally, which is what the user expects.
     *
     * In dev-bypass builds, signing out drops back to SignedOut for
     * one tick so the user sees the SignInScreen; the next process
     * launch will auto-bypass again. The "Skip Sign-In (DEV)" button
     * on SignInScreen lets you opt back in without restarting.
     */
    suspend fun signOut() {
        try {
            api.signOut()
        } catch (e: Throwable) {
            Log.w(TAG, "Sign-out server call failed (continuing): $e")
        }
        secureStore.clear()
        _state.value = AuthState.SignedOut
    }

    /**
     * Local-development escape hatch. Puts the AuthManager into a
     * "no token, but isSignedIn = true" state so the UI shows the
     * Home screen and the ApiClient sends requests with no
     * Authorization header. The server (with DEV_BYPASS_AUTH=1) routes
     * those requests to a static legacy user.
     *
     * Hard-gated on `BuildConfig.DEV_BYPASS_AUTH` so a compiled
     * release build cannot enter this state even if invoked at
     * runtime by mistake -- defense in depth alongside the build
     * config flag itself being false in release.
     */
    fun enableDevBypass() {
        if (!BuildConfig.DEV_BYPASS_AUTH) {
            Log.w(TAG, "enableDevBypass() ignored -- not a debug build")
            return
        }
        _state.value = AuthState(
            accessToken = null,
            isDevBypass = true,
            email = "dev@local",
            name = "Dev User",
        )
    }

    private fun loadInitialState(): AuthState {
        val token = secureStore.getString(SecureStore.KEY_ACCESS_TOKEN)
        if (token != null) {
            return AuthState(
                accessToken = token,
                expiresAt = secureStore.getString(SecureStore.KEY_TOKEN_EXPIRES_AT),
                userID = secureStore.getString(SecureStore.KEY_USER_ID),
                email = secureStore.getString(SecureStore.KEY_USER_EMAIL),
                name = secureStore.getString(SecureStore.KEY_USER_NAME),
            )
        }
        // No persisted session. In debug builds with the bypass flag
        // on, drop straight into a fake-signed-in state so the
        // emulator boots into the Home screen without any sign-in
        // ceremony. Release builds skip this and surface SignInScreen.
        if (BuildConfig.DEV_BYPASS_AUTH) {
            return AuthState(
                accessToken = null,
                isDevBypass = true,
                email = "dev@local",
                name = "Dev User",
            )
        }
        return AuthState.SignedOut
    }

    companion object {
        private const val TAG = "AuthManager"
    }
}

/**
 * Auth state snapshot. `accessToken == null` means signed out, UNLESS
 * `isDevBypass` is true (debug builds only). In that case the user
 * is treated as signed in but no Bearer token is sent on requests --
 * the server's DEV_BYPASS_AUTH escape hatch routes the call to the
 * legacy user.
 *
 * Profile fields are best-effort (we get them from the server's
 * /auth/google response and may be null if the user's identity
 * provider didn't share them).
 */
data class AuthState(
    val accessToken: String? = null,
    val expiresAt: String? = null,
    val userID: String? = null,
    val email: String? = null,
    val name: String? = null,
    val isDevBypass: Boolean = false,
) {
    val isSignedIn: Boolean get() = accessToken != null || isDevBypass

    companion object {
        val SignedOut = AuthState()
    }
}

class AuthException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)
