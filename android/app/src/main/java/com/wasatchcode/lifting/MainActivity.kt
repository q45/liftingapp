package com.wasatchcode.lifting

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.wasatchcode.lifting.auth.AuthState
import com.wasatchcode.lifting.features.home.HomeScreen
import com.wasatchcode.lifting.features.signin.SignInScreen
import com.wasatchcode.lifting.ui.theme.LiftingTheme

/**
 * Single-Activity, Compose-only entry point. The auth state from
 * the app-level AuthManager decides which top-level screen renders.
 * Keep all navigation inside Compose (Navigation Compose) so we
 * never have to juggle Fragments / Activities for app UI.
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val app = application as LiftingApp

        setContent {
            LiftingTheme {
                Root(app = app)
            }
        }
    }
}

@Composable
private fun Root(app: LiftingApp) {
    val authState by app.auth.state.collectAsState()

    // Kick off a sync whenever we transition to a signed-in state.
    // Mirrors the iOS app's configureSyncIfNeeded() call.
    LaunchedEffect(authState.isSignedIn) {
        if (authState.isSignedIn) {
            app.sync.syncNow()
        }
    }

    if (authState.isSignedIn) {
        HomeScreen(
            db = app.database,
            onSignOut = {
                // Caller wraps in a coroutine scope; keep this a
                // suspend lambda so the screen can chain UI updates.
                app.auth.signOut()
            },
            onRefresh = { app.sync.syncNow() },
            user = authState,
        )
    } else {
        SignInScreen(
            authManager = app.auth,
        )
    }
}

/**
 * Re-export so screens importing AuthState don't have to dig into
 * the auth package.
 */
typealias UserState = AuthState
