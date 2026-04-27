package com.wasatchcode.lifting

import android.app.Application
import android.content.SharedPreferences
import com.wasatchcode.lifting.auth.AuthManager
import com.wasatchcode.lifting.data.local.AppDatabase
import com.wasatchcode.lifting.data.remote.ApiClient
import com.wasatchcode.lifting.data.sync.SyncCursorStore
import com.wasatchcode.lifting.data.sync.SyncEngine

/**
 * App-process entry point. Owns the long-lived singletons:
 *   - AppDatabase (Room)
 *   - AuthManager (session JWT + sign-in flow)
 *   - ApiClient (Ktor)
 *   - SyncEngine (Room <-> server reconciliation)
 *
 * Mirrors the iOS `liftingApp.swift` setup, but Android's
 * Application class gives us a process-wide hook that's actually
 * cleaner than SwiftUI's @main + @State.
 *
 * Why no DI framework: this is a single-author codebase with one
 * Activity. Adding Hilt or Koin would be ceremony for the sake of
 * ceremony. If/when we add background workers, multiple modules,
 * or a flavor split, revisit.
 */
class LiftingApp : Application() {

    lateinit var database: AppDatabase
        private set

    lateinit var auth: AuthManager
        private set

    lateinit var sync: SyncEngine
        private set

    override fun onCreate() {
        super.onCreate()

        database = AppDatabase.get(this)

        // ApiClient needs AuthManager's bearer-token closure, but
        // AuthManager wants an api factory. Resolve the chicken-and-
        // egg by giving AuthManager a factory closure that builds
        // the client lazily, capturing AuthManager itself once it's
        // constructed. We hold an outer `var` so the factory's
        // captured reference resolves correctly the first time it's
        // invoked.
        var lateAuth: AuthManager? = null
        val apiFactory: (() -> String?) -> ApiClient = { bearer ->
            ApiClient(
                baseUrl = BuildConfig.DEFAULT_SERVER_URL,
                bearer = bearer,
            )
        }
        auth = AuthManager(
            context = this,
            webClientId = BuildConfig.GOOGLE_WEB_CLIENT_ID,
            apiClientFactory = apiFactory,
        ).also { lateAuth = it }

        val cursorPrefs: SharedPreferences =
            getSharedPreferences("lifting_sync", MODE_PRIVATE)
        sync = SyncEngine(
            db = database,
            api = auth.api,
            cursorStore = SyncCursorStore(cursorPrefs),
        )

        // Trigger an initial sync if we already have a session token
        // from a prior launch. Fire-and-forget; Sync handles its own
        // error reporting via Logcat.
        if (auth.state.value.isSignedIn) {
            sync.scheduleSync()
        }
    }
}
