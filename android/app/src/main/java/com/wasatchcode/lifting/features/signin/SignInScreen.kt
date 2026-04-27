package com.wasatchcode.lifting.features.signin

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wasatchcode.lifting.BuildConfig
import com.wasatchcode.lifting.auth.AuthException
import com.wasatchcode.lifting.auth.AuthManager
import com.wasatchcode.lifting.ui.theme.AppColors
import kotlinx.coroutines.launch

/**
 * Sign-in screen. Single button: Continue with Google.
 *
 * On Android we deliberately omit Sign in with Apple -- the App
 * Store's "must-offer-Apple" rule (guideline 4.8) doesn't apply
 * here, and Apple sign-in on Android requires a web OAuth round
 * trip with extra ceremony. Keep the Android UX simple.
 *
 * Loading vs. error state:
 *   - `loading` covers both the Credential Manager picker and the
 *     server token exchange.
 *   - `error` is a one-line message shown beneath the button.
 *     Cancellation is silent (user knows they cancelled).
 */
@Composable
fun SignInScreen(authManager: AuthManager) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var loading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(AppColors.Bg),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 32.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Glyph stub. Replace with the real launcher icon once
            // the design pass produces one.
            Box(
                modifier = Modifier
                    .size(72.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(AppColors.Accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "L",
                    color = AppColors.Accent,
                    fontWeight = FontWeight.Black,
                    fontSize = 36.sp,
                )
            }

            Spacer(Modifier.height(20.dp))

            Text(
                text = "Lifting",
                color = AppColors.White,
                fontSize = 30.sp,
                fontWeight = FontWeight.Black,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                text = "Log workouts. Track progress. Get smarter.",
                color = AppColors.Muted,
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(48.dp))

            Button(
                onClick = {
                    if (loading) return@Button
                    errorMessage = null
                    loading = true
                    scope.launch {
                        try {
                            authManager.signInWithGoogle(context)
                        } catch (e: AuthException) {
                            errorMessage = e.message
                        } catch (e: Throwable) {
                            errorMessage = "Sign-in failed: ${e.message ?: "unknown error"}"
                        } finally {
                            loading = false
                        }
                    }
                },
                colors = ButtonDefaults.buttonColors(
                    containerColor = AppColors.Accent,
                    contentColor = AppColors.Bg, // black text on yellow
                ),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(54.dp),
            ) {
                if (loading) {
                    CircularProgressIndicator(
                        color = AppColors.Bg,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(20.dp),
                    )
                } else {
                    Text(
                        text = "Continue with Google",
                        fontWeight = FontWeight.Bold,
                        fontSize = 16.sp,
                    )
                }
            }

            errorMessage?.let { msg ->
                Spacer(Modifier.height(16.dp))
                Text(
                    text = msg,
                    color = AppColors.Red,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                )
            }

            // Debug-only "Skip Sign-In" affordance. Compiles to a
            // no-op in release because BuildConfig.DEV_BYPASS_AUTH
            // is hard-coded to false there and the dead branch gets
            // stripped by R8. Sits below the primary action with
            // muted styling so it's findable but not the visual
            // focus during a real sign-in attempt.
            if (BuildConfig.DEV_BYPASS_AUTH) {
                Spacer(Modifier.height(20.dp))
                Text(
                    text = "DEV ONLY",
                    color = AppColors.MutedDeep,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.sp,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    text = "Skip Sign-In",
                    color = AppColors.Accent,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clickable { authManager.enableDevBypass() }
                        .padding(8.dp),
                )
                Text(
                    text = "Routes requests through DEV_BYPASS_AUTH on the server.",
                    color = AppColors.MutedDeep,
                    fontSize = 11.sp,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
