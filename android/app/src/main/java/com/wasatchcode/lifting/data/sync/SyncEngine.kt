package com.wasatchcode.lifting.data.sync

import android.util.Log
import com.wasatchcode.lifting.data.dto.WorkoutSessionDTO
import com.wasatchcode.lifting.data.dto.WorkoutSetDTO
import com.wasatchcode.lifting.data.dto.ExerciseEntryDTO
import com.wasatchcode.lifting.data.local.AppDatabase
import com.wasatchcode.lifting.data.models.WorkoutSessionEntity
import com.wasatchcode.lifting.data.models.WorkoutSetEntity
import com.wasatchcode.lifting.data.models.ExerciseEntryEntity
import com.wasatchcode.lifting.data.remote.ApiClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.util.UUID

/**
 * SyncEngine: keeps the local Room DB in sync with the server.
 *
 * Same architecture as iOS lifting/SyncEngine.swift:
 *   - PUSH: walk dirty rows (needsSync = true), PUT them, clear the
 *     dirty bit on success. Parents before children.
 *   - PULL: GET /sync/changes?since=<lastCursor>, apply each row
 *     using last-write-wins (drop any incoming row whose updatedAt
 *     <= the local copy's). Save the response's serverTime as the
 *     new cursor.
 *   - Trigger: scheduleSync() debounces multiple rapid mutations
 *     into one round-trip. App-resume / pull-to-refresh / a manual
 *     refresh button can call syncNow() directly.
 *
 * This is a *skeleton* -- the wire format is fully implemented but
 * only the workout-session / exercise / set tables are wired through
 * push and pull. Templates, profile, and body-weight follow the same
 * pattern; copy-paste each block as you light up those screens.
 *
 * The SyncEngine itself is intentionally not injected via Hilt or
 * Koin -- a single instance lives in `LiftingApp` for the app
 * lifetime, mirroring the iOS `SyncEngine.shared` pattern. If we
 * later want per-user isolation we can scope it to the Activity.
 */
class SyncEngine(
    private val db: AppDatabase,
    private val api: ApiClient,
    private val cursorStore: SyncCursorStore,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val triggerChannel = Channel<Unit>(Channel.CONFLATED)

    @Volatile private var running: Job? = null

    init {
        // Drain the channel: every emission triggers one sync pass.
        // Channel is CONFLATED so a flurry of mutations during a
        // logging session collapses into a single sync.
        scope.launch {
            triggerChannel.consumeAsFlow().collect {
                runSyncSafely()
            }
        }
    }

    /** Fire-and-forget. Coalesces with any in-flight syncs. */
    fun scheduleSync() {
        triggerChannel.trySend(Unit)
    }

    /**
     * Suspend until the next sync pass completes. Used by pull-to-
     * refresh and the "I just signed in" hand-off.
     */
    suspend fun syncNow() {
        runSyncSafely()
    }

    private suspend fun runSyncSafely() = withContext(Dispatchers.IO) {
        if (running?.isActive == true) {
            // A pass is already in flight; conflate -- no need to
            // queue a duplicate.
            return@withContext
        }
        running = scope.launch {
            try {
                push()
                pull()
            } catch (e: Throwable) {
                Log.w(TAG, "Sync failed (will retry on next trigger)", e)
                // Soft retry: not blocking; caller can scheduleSync
                // again. For unattended retry, install a periodic
                // WorkManager job.
                delay(2_000)
            }
        }
        running?.join()
    }

    // ---------------------------------------------------------------
    // PUSH
    // ---------------------------------------------------------------

    private suspend fun push() {
        // Parents before children: session -> exercise -> set. That
        // way when a child references its parent_id server-side, the
        // FK target already exists.
        pushSessions()
        pushExercises()
        pushSets()
        // TODO: pushTemplates / pushTemplateExercises / pushProfile /
        // pushBodyWeight -- same shape as the three above.
    }

    private suspend fun pushSessions() {
        val dirty = db.sessions().dirty()
        for (row in dirty) {
            try {
                api.upsertWorkoutSession(row.toDto())
                db.sessions().upsert(row.copy(needsSync = false))
            } catch (e: Throwable) {
                Log.w(TAG, "Failed to push session ${row.id}: ${e.message}")
            }
        }
    }

    private suspend fun pushExercises() {
        val dirty = db.exercises().dirty()
        for (row in dirty) {
            try {
                api.upsertExerciseEntry(row.toDto())
                db.exercises().upsert(row.copy(needsSync = false))
            } catch (e: Throwable) {
                Log.w(TAG, "Failed to push exercise ${row.id}: ${e.message}")
            }
        }
    }

    private suspend fun pushSets() {
        val dirty = db.sets().dirty()
        for (row in dirty) {
            try {
                api.upsertWorkoutSet(row.toDto())
                db.sets().upsert(row.copy(needsSync = false))
            } catch (e: Throwable) {
                Log.w(TAG, "Failed to push set ${row.id}: ${e.message}")
            }
        }
    }

    // ---------------------------------------------------------------
    // PULL
    // ---------------------------------------------------------------

    private suspend fun pull() {
        val since = cursorStore.lastSync()
        val changes = api.syncChanges(since)

        // Sessions
        for (dto in changes.workoutSessions) {
            applySession(dto)
        }
        for (dto in changes.exerciseEntries) {
            applyExercise(dto)
        }
        for (dto in changes.workoutSets) {
            applySet(dto)
        }
        // TODO: templates / templateExercises / userProfile /
        // bodyWeightEntries -- same LWW pattern.

        cursorStore.setLastSync(changes.serverTime)
    }

    private suspend fun applySession(dto: WorkoutSessionDTO) {
        val existing = db.sessions().byID(dto.id)
        // LWW: drop incoming if we have a strictly newer local copy.
        val incomingMillis = isoToMillis(dto.updatedAt)
        if (existing != null && existing.updatedAt >= incomingMillis) return
        db.sessions().upsert(
            (existing ?: WorkoutSessionEntity(
                id = dto.id,
                startTime = isoToMillis(dto.startTime),
                endTime = isoToMillis(dto.endTime),
                updatedAt = incomingMillis,
            )).copy(
                startTime = isoToMillis(dto.startTime),
                endTime = isoToMillis(dto.endTime),
                isCompleted = dto.isCompleted,
                startedFromTemplateID = dto.startedFromTemplateID,
                updatedAt = incomingMillis,
                deletedAt = dto.deletedAt?.let(::isoToMillis),
                needsSync = false,
            ),
        )
    }

    private suspend fun applyExercise(dto: ExerciseEntryDTO) {
        val incomingMillis = isoToMillis(dto.updatedAt)
        val entity = ExerciseEntryEntity(
            id = dto.id,
            sessionID = dto.sessionID,
            name = dto.name,
            category = dto.category,
            order = dto.order,
            updatedAt = incomingMillis,
            deletedAt = dto.deletedAt?.let(::isoToMillis),
            needsSync = false,
        )
        db.exercises().upsert(entity)
    }

    private suspend fun applySet(dto: WorkoutSetDTO) {
        val incomingMillis = isoToMillis(dto.updatedAt)
        val entity = WorkoutSetEntity(
            id = dto.id,
            exerciseID = dto.exerciseID,
            weight = dto.weight,
            reps = dto.reps,
            durationSeconds = dto.durationSeconds,
            order = dto.order,
            updatedAt = incomingMillis,
            deletedAt = dto.deletedAt?.let(::isoToMillis),
            needsSync = false,
        )
        db.sets().upsert(entity)
    }

    companion object {
        private const val TAG = "SyncEngine"
    }
}

// -------------------------------------------------------------------
// Cursor persistence
// -------------------------------------------------------------------

/**
 * Persists the "since" cursor for /sync/changes. Backed by a tiny
 * SharedPreferences entry rather than DataStore -- the access
 * pattern is read-once-write-rarely and DataStore is overkill.
 */
class SyncCursorStore(private val prefs: android.content.SharedPreferences) {
    suspend fun lastSync(): String? = withContext(Dispatchers.IO) {
        prefs.getString(KEY, null)
    }

    suspend fun setLastSync(iso: String) = withContext(Dispatchers.IO) {
        prefs.edit().putString(KEY, iso).apply()
    }

    companion object {
        private const val KEY = "sync_last_cursor"
    }
}

// -------------------------------------------------------------------
// Entity <-> DTO converters
// -------------------------------------------------------------------
//
// Lives next to SyncEngine because that's the only caller. Splitting
// into a separate Mapper.kt is fine if these grow, but for ~50 lines
// it's clearer in-line.

private fun WorkoutSessionEntity.toDto() = WorkoutSessionDTO(
    id = id,
    startTime = millisToIso(startTime),
    endTime = millisToIso(endTime),
    isCompleted = isCompleted,
    startedFromTemplateID = startedFromTemplateID,
    updatedAt = millisToIso(updatedAt),
    deletedAt = deletedAt?.let(::millisToIso),
)

private fun ExerciseEntryEntity.toDto() = ExerciseEntryDTO(
    id = id,
    sessionID = sessionID,
    name = name,
    category = category,
    order = order,
    updatedAt = millisToIso(updatedAt),
    deletedAt = deletedAt?.let(::millisToIso),
)

private fun WorkoutSetEntity.toDto() = WorkoutSetDTO(
    id = id,
    exerciseID = exerciseID,
    weight = weight,
    reps = reps,
    durationSeconds = durationSeconds,
    order = order,
    updatedAt = millisToIso(updatedAt),
    deletedAt = deletedAt?.let(::millisToIso),
)

private fun isoToMillis(iso: String): Long =
    try { Instant.parse(iso).toEpochMilli() } catch (_: Throwable) { System.currentTimeMillis() }

private fun millisToIso(millis: Long): String =
    Instant.ofEpochMilli(millis).toString()
