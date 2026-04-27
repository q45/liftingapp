package com.wasatchcode.lifting.data.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire DTOs. Mirror server/src/schemas.ts (Zod) and
 * lifting/DataLayer.swift (Codable). Field names match the JSON the
 * server already produces, so kotlinx.serialization's default
 * naming strategy works without per-field @SerialName overrides.
 *
 * Dates are passed as ISO-8601 strings on the wire (the server emits
 * `"2025-04-21T18:32:11Z"`). We keep them as String here and convert
 * to/from epoch millis at the model boundary -- avoids coupling this
 * file to a specific date library and keeps Serializer codegen
 * simple.
 *
 * Optional/nullable fields that the server treats as
 * `.nullable().optional()` are declared with default values so a
 * missing field on the wire decodes correctly.
 */

// ---- Auth ----

@Serializable
data class GoogleExchangeRequestDTO(
    val identityToken: String,
)

@Serializable
data class AuthUserDTO(
    val id: String,
    val email: String? = null,
    val name: String? = null,
)

@Serializable
data class AuthResponseDTO(
    val accessToken: String,
    /** ISO-8601 expiry. */
    val expiresAt: String,
    val user: AuthUserDTO,
)

// ---- Sets ----

@Serializable
data class WorkoutSetDTO(
    val id: String,
    val exerciseID: String? = null,
    val weight: Double,
    val reps: Int,
    /** Non-null for timed sets (plank, dead hang, AMRAP-window). */
    val durationSeconds: Int? = null,
    val order: Int,
    val updatedAt: String,
    val deletedAt: String? = null,
)

// ---- Exercises ----

@Serializable
data class ExerciseEntryDTO(
    val id: String,
    val sessionID: String? = null,
    val name: String,
    val category: String,
    val order: Int,
    val sets: List<WorkoutSetDTO> = emptyList(),
    val updatedAt: String,
    val deletedAt: String? = null,
)

// ---- Sessions ----

@Serializable
data class WorkoutSessionDTO(
    val id: String,
    val startTime: String,
    val endTime: String,
    val isCompleted: Boolean,
    val startedFromTemplateID: String? = null,
    val exercises: List<ExerciseEntryDTO> = emptyList(),
    val updatedAt: String,
    val deletedAt: String? = null,
)

// ---- Templates ----

@Serializable
data class TemplateExerciseDTO(
    val id: String,
    val templateID: String? = null,
    val name: String,
    val category: String,
    val order: Int,
    val updatedAt: String,
    val deletedAt: String? = null,
)

@Serializable
data class WorkoutTemplateDTO(
    val id: String,
    val name: String,
    val order: Int,
    val exercises: List<TemplateExerciseDTO> = emptyList(),
    val updatedAt: String,
    val deletedAt: String? = null,
)

// ---- Profile + body weight ----

@Serializable
data class UserProfileDTO(
    val birthYear: Int? = null,
    val sex: String? = null,
    val heightCm: Double? = null,
    val experienceLevel: String? = null,
    val trainingDaysPerWeek: Int? = null,
    val primaryGoal: String? = null,
    val equipmentAccess: String? = null,
    val preferredUnit: String? = null,
    val notes: String? = null,
    val updatedAt: String,
    val deletedAt: String? = null,
)

@Serializable
data class BodyWeightEntryDTO(
    val id: String,
    val weightKg: Double,
    val measuredAt: String,
    val notes: String? = null,
    val updatedAt: String,
    val deletedAt: String? = null,
)

// ---- /sync/changes ----

@Serializable
data class SyncChangesDTO(
    val serverTime: String,
    val workoutSessions: List<WorkoutSessionDTO> = emptyList(),
    val exerciseEntries: List<ExerciseEntryDTO> = emptyList(),
    val workoutSets: List<WorkoutSetDTO> = emptyList(),
    val workoutTemplates: List<WorkoutTemplateDTO> = emptyList(),
    val templateExercises: List<TemplateExerciseDTO> = emptyList(),
    /** Singleton or null when unchanged. */
    val userProfile: UserProfileDTO? = null,
    val bodyWeightEntries: List<BodyWeightEntryDTO> = emptyList(),
)

// ---- Coach ----

@Serializable
data class CoachRecommendationDTO(
    val exerciseName: String,
    val weight: Double,
    val sets: Int,
    val reps: Int,
    val tip: String,
)

@Serializable
data class CoachResultDTO(
    val summary: String,
    val recommendations: List<CoachRecommendationDTO>,
)

@Serializable
data class CoachResponseDTO(
    val createdAt: String,
    val expiresAt: String,
    val cached: Boolean,
    val model: String,
    val goal: String,
    val unit: String,
    val result: CoachResultDTO,
)

@Serializable
data class CoachRequestDTO(
    val goal: String,
    val unit: String,
    @SerialName("refresh") val forceRefresh: Boolean = false,
)
