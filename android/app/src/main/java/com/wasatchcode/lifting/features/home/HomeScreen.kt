package com.wasatchcode.lifting.features.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.border
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.wasatchcode.lifting.UserState
import com.wasatchcode.lifting.data.local.AppDatabase
import com.wasatchcode.lifting.data.models.WorkoutSessionEntity
import com.wasatchcode.lifting.ui.theme.AppColors
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/**
 * Minimal Home screen for the dogfood build. Shows:
 *   - Greeting + signed-in user
 *   - This-week stats card (workout count, volume)
 *   - Recent Workouts list (last 6 from Room)
 *   - Sign-out button
 *
 * Once you start porting the iOS Home, History, Workout, Coach
 * screens, this becomes a NavHost root rather than a single Column.
 * The data wiring (Room queries, dirty flag, sync trigger) is the
 * hard part and is already done by the time you reach those.
 *
 * What's deliberately missing for v0:
 *   - Tab bar / bottom navigation -- single screen for now
 *   - Start Workout button is non-functional -- WorkoutScreen
 *     hasn't been ported yet
 *   - Recent Workouts rows aren't tappable -- WorkoutDetailScreen
 *     is a follow-up file
 */
@Composable
fun HomeScreen(
    db: AppDatabase,
    user: UserState,
    onSignOut: suspend () -> Unit,
    onRefresh: suspend () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val sessions by db.sessions().observeCompleted()
        .collectAsState(initial = emptyList())

    val recent = sessions.take(6)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(AppColors.Bg)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(top = 24.dp, bottom = 32.dp),
    ) {
        header(user)
        Spacer(Modifier.height(18.dp))

        StatsRow(sessions = sessions)
        Spacer(Modifier.height(18.dp))

        // Refresh button -- explicit while we don't have a real
        // pull-to-refresh wired (Compose has nestedScroll APIs but
        // they need real care to feel right; defer to later).
        SectionLabel("Recent Workouts")
        Spacer(Modifier.height(10.dp))
        if (recent.isEmpty()) {
            EmptyCard(
                title = "No workouts yet",
                subtitle = "Log a workout on iOS to see it sync here, or wait for the Workout screen to land on Android.",
            )
        } else {
            recent.forEachIndexed { i, session ->
                WorkoutRow(session)
                if (i != recent.lastIndex) Spacer(Modifier.height(8.dp))
            }
        }

        Spacer(Modifier.height(24.dp))

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(AppColors.Card)
                .border(1.dp, AppColors.Border, RoundedCornerShape(12.dp))
                .clickable {
                    scope.launch { onRefresh() }
                }
                .padding(14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "Refresh from server",
                color = AppColors.Accent,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
            )
        }

        Spacer(Modifier.height(10.dp))

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Color.Transparent)
                .border(1.dp, AppColors.Border, RoundedCornerShape(12.dp))
                .clickable {
                    scope.launch { onSignOut() }
                }
                .padding(14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "Sign out",
                color = AppColors.Muted,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
            )
        }
    }
}

// MARK: - Subviews

@Composable
private fun header(user: UserState) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = LocalDate.now().format(DateTimeFormatter.ofPattern("EEEE, MMM d")),
                color = AppColors.Muted,
                fontSize = 13.sp,
                modifier = Modifier.weight(1f),
            )
            // Bypass badge: makes it impossible to forget you're in
            // an authenticated-but-no-real-user state.
            if (user.isDevBypass) {
                Text(
                    text = "DEV",
                    color = AppColors.Bg,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = 1.sp,
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .background(AppColors.Accent)
                        .padding(horizontal = 7.dp, vertical = 3.dp),
                )
            }
        }
        Spacer(Modifier.height(2.dp))
        Text(
            text = "Ready to lift?",
            color = AppColors.White,
            fontSize = 30.sp,
            fontWeight = FontWeight.Black,
        )
        user.email?.let {
            Spacer(Modifier.height(4.dp))
            Text(
                text = if (user.isDevBypass)
                    "Bypass mode \u00b7 server's legacy user"
                else
                    "Signed in as $it",
                color = AppColors.MutedDeep,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun StatsRow(sessions: List<WorkoutSessionEntity>) {
    val now = Instant.now().toEpochMilli()
    val sevenDaysAgo = now - 7L * 24 * 60 * 60 * 1000
    val weekCount = sessions.count { it.endTime >= sevenDaysAgo }
    val streak = computeStreak(sessions)

    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StatCard(
            value = weekCount.toString(),
            sub = if (weekCount == 1) "workout" else "workouts",
            label = "This Week",
            modifier = Modifier.weight(1f),
        )
        StatCard(
            value = sessions.size.toString(),
            sub = "total",
            label = "All Time",
            modifier = Modifier.weight(1f),
        )
        StatCard(
            value = streak.toString(),
            sub = "days",
            label = "Streak",
            modifier = Modifier.weight(1f),
        )
    }
}

private fun computeStreak(sessions: List<WorkoutSessionEntity>): Int {
    if (sessions.isEmpty()) return 0
    val zone = ZoneId.systemDefault()
    val days = sessions
        .map { Instant.ofEpochMilli(it.endTime).atZone(zone).toLocalDate() }
        .toSet()
    var streak = 0
    var day = LocalDate.now()
    while (days.contains(day)) {
        streak += 1
        day = day.minusDays(1)
    }
    return streak
}

@Composable
private fun StatCard(value: String, sub: String, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(AppColors.Card)
            .border(1.dp, AppColors.Border, RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        Text(
            text = label.uppercase(),
            color = AppColors.Muted,
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.6.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = value,
            color = AppColors.White,
            fontSize = 24.sp,
            fontWeight = FontWeight.Black,
            fontFamily = FontFamily.Monospace,
        )
        Text(
            text = sub,
            color = AppColors.Muted,
            fontSize = 11.sp,
        )
    }
}

@Composable
private fun WorkoutRow(session: WorkoutSessionEntity) {
    val date = Instant.ofEpochMilli(session.endTime)
        .atZone(ZoneId.systemDefault())
        .toLocalDate()
    val durationMin = ChronoUnit.MINUTES
        .between(
            Instant.ofEpochMilli(session.startTime),
            Instant.ofEpochMilli(session.endTime),
        )
        .coerceAtLeast(0)

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(AppColors.Card)
            .border(1.dp, AppColors.Border, RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    text = date.format(DateTimeFormatter.ofPattern("EEE, MMM d")),
                    color = AppColors.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "$durationMin min",
                    color = AppColors.Muted,
                    fontSize = 12.sp,
                )
            }
            Text(
                text = "›",
                color = AppColors.Muted,
                fontSize = 18.sp,
            )
        }
    }
}

@Composable
private fun EmptyCard(title: String, subtitle: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(AppColors.Card)
            .border(1.dp, AppColors.Border, RoundedCornerShape(14.dp))
            .padding(16.dp),
    ) {
        Text(
            text = title,
            color = AppColors.White,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = subtitle,
            color = AppColors.Muted,
            fontSize = 13.sp,
            textAlign = TextAlign.Start,
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = AppColors.Muted,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.8.sp,
    )
}
