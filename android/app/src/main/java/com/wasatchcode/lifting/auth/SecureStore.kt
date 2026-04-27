package com.wasatchcode.lifting.auth

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Encrypted SharedPreferences for the session JWT and any other
 * secret-ish values. Equivalent to the iOS app's KeychainHelper.
 *
 * Why EncryptedSharedPreferences and not plain Preferences DataStore:
 *   - It transparently encrypts both keys and values using the
 *     Android Keystore-backed master key, which is the closest
 *     parallel to the iOS Keychain.
 *   - DataStore Preferences doesn't have a first-party encryption
 *     story today; we'd be DIY-encrypting either way.
 *
 * The library is in alpha for AndroidX 2024+, but the underlying
 * Tink encryption is stable and the API surface is small enough
 * to swap if a 1.0 release renames something.
 */
class SecureStore(context: Context) {
    private val prefs: SharedPreferences = run {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun getString(key: String): String? = prefs.getString(key, null)

    fun putString(key: String, value: String?) {
        prefs.edit().apply {
            if (value == null) remove(key) else putString(key, value)
            apply()
        }
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    companion object {
        private const val FILE_NAME = "lifting_secure"

        const val KEY_ACCESS_TOKEN = "access_token"
        const val KEY_TOKEN_EXPIRES_AT = "access_token_expires_at"
        const val KEY_USER_ID = "user_id"
        const val KEY_USER_EMAIL = "user_email"
        const val KEY_USER_NAME = "user_name"
    }
}
