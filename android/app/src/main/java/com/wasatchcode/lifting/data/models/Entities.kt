package com.wasatchcode.lifting.data.models

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.UUID

/**
 * Room entities. Direct mirror of the iOS `@Model` classes in
 * lifting/Models.swift. Same UUID-keyed identity model, same sync
 * columns (`updatedAt`, `deletedAt`, `needsSync`), same parent/child
 * relationships expressed as foreign keys.
 *
 * UUIDs are stored as String (Room doesn't natively know UUID; the
 * conversion happens on read/write via UUID.fromString / .toString).
 * Dates stored as Long (epoch millis) for the same reason -- Room
 * has TypeConverters but a single Long column is simpler and matches
 * how the SyncEngine ultimately serializes them anyway.
 */

// MARK: - Workout session

@Entity(
    tableName = "workout_sessions",
    indices = [
        Index(value = ["isCompleted"]),
        Index(value = ["endTime"]),
    ],
)
data class WorkoutSessionEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    /** Epoch millis. */
    val startTime: Long,
    /** Epoch millis. */
    val endTime: Long,
    /** False during an active workout; flipped true on finish. */
    val isCompleted: Boolean = false,
    /** Weak reference to the WorkoutTemplate this session was started
     *  from. Nullable; analytics-only. Mirrors the iOS field. */
    val startedFromTemplateID: String? = null,
    /** Sync columns. */
    val updatedAt: Long,
    val deletedAt: Long? = null,
    val needsSync: Boolean = true,
)

// MARK: - Exercise entry

@Entity(
    tableName = "exercise_entries",
    foreignKeys = [
        ForeignKey(
            entity = WorkoutSessionEntity::class,
            parentColumns = ["id"],
            childColumns = ["sessionID"],
            onDelete = ForeignKey.SET_NULL,
        ),
    ],
    indices = [
        Index(value = ["sessionID"]),
        Index(value = ["name"]),
    ],
)
data class ExerciseEntryEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val sessionID: String?,
    val name: String,
    val category: String,
    val order: Int,
    val updatedAt: Long,
    val deletedAt: Long? = null,
    val needsSync: Boolean = true,
)

// MARK: - Workout set

@Entity(
    tableName = "workout_sets",
    foreignKeys = [
        ForeignKey(
            entity = ExerciseEntryEntity::class,
            parentColumns = ["id"],
            childColumns = ["exerciseID"],
            onDelete = ForeignKey.SET_NULL,
        ),
    ],
    indices = [Index(value = ["exerciseID"])],
)
data class WorkoutSetEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val exerciseID: String?,
    val weight: Double,
    val reps: Int,
    /** When non-null the set was timed (plank, dead hang). Mirrors
     *  WorkoutSet.durationSeconds on iOS. */
    val durationSeconds: Int? = null,
    val order: Int,
    val updatedAt: Long,
    val deletedAt: Long? = null,
    val needsSync: Boolean = true,
)

// MARK: - Templates

@Entity(tableName = "workout_templates")
data class WorkoutTemplateEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val name: String,
    val order: Int,
    val updatedAt: Long,
    val deletedAt: Long? = null,
    val needsSync: Boolean = true,
)

@Entity(
    tableName = "template_exercises",
    foreignKeys = [
        ForeignKey(
            entity = WorkoutTemplateEntity::class,
            parentColumns = ["id"],
            childColumns = ["templateID"],
            onDelete = ForeignKey.SET_NULL,
        ),
    ],
    indices = [Index(value = ["templateID"])],
)
data class TemplateExerciseEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val templateID: String?,
    val name: String,
    val category: String,
    val order: Int,
    val updatedAt: Long,
    val deletedAt: Long? = null,
    val needsSync: Boolean = true,
)

// MARK: - User profile (singleton per user)

@Entity(tableName = "user_profile")
data class UserProfileEntity(
    /** There's only ever one row; we still use a String PK rather
     *  than a synthetic Boolean key for parity with the rest of the
     *  schema. iOS uses a UUID singleton constant; we follow suit. */
    @PrimaryKey val id: String = SINGLETON_ID,
    val birthYear: Int? = null,
    val sex: String? = null,
    val heightCm: Double? = null,
    val experienceLevel: String? = null,
    val trainingDaysPerWeek: Int? = null,
    val primaryGoal: String? = null,
    val equipmentAccess: String? = null,
    val preferredUnit: String? = null,
    val notes: String? = null,
    val updatedAt: Long,
    val deletedAt: Long? = null,
    val needsSync: Boolean = false, // empty profile shouldn't push
) {
    companion object {
        const val SINGLETON_ID = "00000000-0000-0000-0000-000000000001"
    }
}

// MARK: - Body weight log

@Entity(
    tableName = "body_weight_log",
    indices = [Index(value = ["measuredAt"])],
)
data class BodyWeightEntryEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    /** Canonical storage unit is kg; UI converts for display. */
    val weightKg: Double,
    /** Epoch millis. User-provided; can be backdated. */
    val measuredAt: Long,
    val notes: String? = null,
    val updatedAt: Long,
    val deletedAt: Long? = null,
    val needsSync: Boolean = true,
)
