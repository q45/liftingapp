package com.wasatchcode.lifting.data.local

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Update
import com.wasatchcode.lifting.data.models.BodyWeightEntryEntity
import com.wasatchcode.lifting.data.models.ExerciseEntryEntity
import com.wasatchcode.lifting.data.models.TemplateExerciseEntity
import com.wasatchcode.lifting.data.models.UserProfileEntity
import com.wasatchcode.lifting.data.models.WorkoutSessionEntity
import com.wasatchcode.lifting.data.models.WorkoutSetEntity
import com.wasatchcode.lifting.data.models.WorkoutTemplateEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Objects (DAOs) for every Room entity. We keep one DAO
 * per entity but a single AppDatabase wires them all together. The
 * SyncEngine and ViewModels both depend on these directly -- there's
 * no repository indirection layer for v1, mirroring how the iOS app
 * has WorkoutManager talk to ModelContext directly.
 *
 * Convention: returning Flow for UI subscriptions, plain suspend for
 * commands. `liveSessions()` and friends filter out tombstones at the
 * query level so callers don't have to remember to .filter on
 * deletedAt every time.
 */

@Dao
interface WorkoutSessionDao {
    @Query("""SELECT * FROM workout_sessions
              WHERE deletedAt IS NULL AND isCompleted = 1
              ORDER BY endTime DESC""")
    fun observeCompleted(): Flow<List<WorkoutSessionEntity>>

    @Query("""SELECT * FROM workout_sessions
              WHERE deletedAt IS NULL AND isCompleted = 0
              ORDER BY startTime DESC LIMIT 1""")
    suspend fun activeSession(): WorkoutSessionEntity?

    @Query("SELECT * FROM workout_sessions WHERE id = :id")
    suspend fun byID(id: String): WorkoutSessionEntity?

    @Query("SELECT * FROM workout_sessions WHERE needsSync = 1")
    suspend fun dirty(): List<WorkoutSessionEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(session: WorkoutSessionEntity)

    @Update
    suspend fun update(session: WorkoutSessionEntity)
}

@Dao
interface ExerciseEntryDao {
    @Query("""SELECT * FROM exercise_entries
              WHERE sessionID = :sessionID AND deletedAt IS NULL
              ORDER BY `order` ASC""")
    fun observeForSession(sessionID: String): Flow<List<ExerciseEntryEntity>>

    @Query("""SELECT * FROM exercise_entries
              WHERE sessionID = :sessionID AND deletedAt IS NULL
              ORDER BY `order` ASC""")
    suspend fun forSession(sessionID: String): List<ExerciseEntryEntity>

    @Query("SELECT * FROM exercise_entries WHERE needsSync = 1")
    suspend fun dirty(): List<ExerciseEntryEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entry: ExerciseEntryEntity)
}

@Dao
interface WorkoutSetDao {
    @Query("""SELECT * FROM workout_sets
              WHERE exerciseID = :exerciseID AND deletedAt IS NULL
              ORDER BY `order` ASC""")
    fun observeForExercise(exerciseID: String): Flow<List<WorkoutSetEntity>>

    @Query("""SELECT * FROM workout_sets
              WHERE exerciseID = :exerciseID AND deletedAt IS NULL
              ORDER BY `order` ASC""")
    suspend fun forExercise(exerciseID: String): List<WorkoutSetEntity>

    @Query("SELECT * FROM workout_sets WHERE needsSync = 1")
    suspend fun dirty(): List<WorkoutSetEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(set: WorkoutSetEntity)
}

@Dao
interface WorkoutTemplateDao {
    @Query("""SELECT * FROM workout_templates
              WHERE deletedAt IS NULL
              ORDER BY `order` ASC, name ASC""")
    fun observeLive(): Flow<List<WorkoutTemplateEntity>>

    @Query("SELECT * FROM workout_templates WHERE needsSync = 1")
    suspend fun dirty(): List<WorkoutTemplateEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(template: WorkoutTemplateEntity)
}

@Dao
interface TemplateExerciseDao {
    @Query("""SELECT * FROM template_exercises
              WHERE templateID = :templateID AND deletedAt IS NULL
              ORDER BY `order` ASC""")
    suspend fun forTemplate(templateID: String): List<TemplateExerciseEntity>

    @Query("SELECT * FROM template_exercises WHERE needsSync = 1")
    suspend fun dirty(): List<TemplateExerciseEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entry: TemplateExerciseEntity)
}

@Dao
interface UserProfileDao {
    @Query("SELECT * FROM user_profile WHERE id = :id LIMIT 1")
    fun observe(id: String = UserProfileEntity.SINGLETON_ID): Flow<UserProfileEntity?>

    @Query("SELECT * FROM user_profile WHERE needsSync = 1 LIMIT 1")
    suspend fun dirty(): UserProfileEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(profile: UserProfileEntity)
}

@Dao
interface BodyWeightEntryDao {
    @Query("""SELECT * FROM body_weight_log
              WHERE deletedAt IS NULL
              ORDER BY measuredAt DESC""")
    fun observeAll(): Flow<List<BodyWeightEntryEntity>>

    @Query("""SELECT * FROM body_weight_log
              WHERE deletedAt IS NULL
              ORDER BY measuredAt DESC LIMIT 1""")
    suspend fun latest(): BodyWeightEntryEntity?

    @Query("SELECT * FROM body_weight_log WHERE needsSync = 1")
    suspend fun dirty(): List<BodyWeightEntryEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entry: BodyWeightEntryEntity)
}

/**
 * Convenience DAO for "fully resolve a session and all its
 * descendants in one call". Used by WorkoutDetailScreen and the
 * sync push path. Saves N+1 round-trips on hot reads.
 */
@Dao
interface SessionGraphDao {
    @Transaction
    suspend fun fullSession(
        sessionID: String,
        sessionDao: WorkoutSessionDao,
        exerciseDao: ExerciseEntryDao,
        setDao: WorkoutSetDao,
    ): SessionGraph? {
        val session = sessionDao.byID(sessionID) ?: return null
        val exercises = exerciseDao.forSession(sessionID)
        val byExercise: Map<String, List<WorkoutSetEntity>> = exercises
            .associate { it.id to setDao.forExercise(it.id) }
        return SessionGraph(session, exercises, byExercise)
    }
}

/** Read-only aggregate used by the sync-push pipeline + detail view. */
data class SessionGraph(
    val session: WorkoutSessionEntity,
    val exercises: List<ExerciseEntryEntity>,
    val setsByExercise: Map<String, List<WorkoutSetEntity>>,
)
