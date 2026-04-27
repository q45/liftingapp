package com.wasatchcode.lifting.data.remote

import android.util.Log
import com.wasatchcode.lifting.data.dto.AuthResponseDTO
import com.wasatchcode.lifting.data.dto.BodyWeightEntryDTO
import com.wasatchcode.lifting.data.dto.CoachRequestDTO
import com.wasatchcode.lifting.data.dto.CoachResponseDTO
import com.wasatchcode.lifting.data.dto.ExerciseEntryDTO
import com.wasatchcode.lifting.data.dto.GoogleExchangeRequestDTO
import com.wasatchcode.lifting.data.dto.SyncChangesDTO
import com.wasatchcode.lifting.data.dto.UserProfileDTO
import com.wasatchcode.lifting.data.dto.WorkoutSessionDTO
import com.wasatchcode.lifting.data.dto.WorkoutSetDTO
import com.wasatchcode.lifting.data.dto.WorkoutTemplateDTO
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.engine.android.Android
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.defaultRequest
import io.ktor.client.plugins.logging.LogLevel
import io.ktor.client.plugins.logging.Logging
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json

/**
 * HTTP client for the Lifting server. 1:1 mirror of
 * lifting/DataLayer.swift's `LiftingAPIClient`. Same endpoints,
 * same DTO shapes, same error semantics.
 *
 * Auth: a session JWT is supplied per-request via the `bearer`
 * lambda. Reading token state through a closure (rather than baking
 * it in at construction) lets AuthManager swap tokens without
 * rebuilding the client. Closure returns null when signed out --
 * dev builds rely on the server's DEV_BYPASS_AUTH escape hatch in
 * that case.
 *
 * Errors: maps non-2xx responses to ApiException. The server's error
 * envelope is `{"error": "...", "message": "..."}`; we extract
 * whichever is present so logs are useful.
 */
class ApiClient(
    private val baseUrl: String,
    private val bearer: () -> String?,
) {
    private val json = Json {
        ignoreUnknownKeys = true   // tolerate forward-compat additions
        explicitNulls = false      // omit nulls on the wire
        prettyPrint = false
    }

    private val client: HttpClient = HttpClient(Android) {
        install(ContentNegotiation) {
            json(json)
        }
        install(Logging) {
            level = LogLevel.INFO
            // Block body, not `=`, because `Log.d()` returns `Int`
            // (the byte count it wrote). Expression-body would infer
            // the override's return type as Int, but the Ktor
            // interface declares `fun log(message: String): Unit`.
            logger = object : io.ktor.client.plugins.logging.Logger {
                override fun log(message: String) {
                    Log.d(TAG, message)
                }
            }
        }
        install(HttpTimeout) {
            requestTimeoutMillis = 60_000
            connectTimeoutMillis = 15_000
            socketTimeoutMillis = 60_000
        }
        defaultRequest {
            // Most requests need JSON. Endpoints that don't (DELETE,
            // empty PUT) override locally.
            contentType(ContentType.Application.Json)
        }
    }

    // -----------------------------------------------------------------
    // Auth
    // -----------------------------------------------------------------

    /**
     * POST /auth/google. Send the Google ID token issued by the
     * Credential Manager flow; receive a server JWT + user profile.
     * Caller is expected to persist `accessToken` in
     * EncryptedSharedPreferences via AuthManager.
     */
    suspend fun exchangeGoogleIdentityToken(idToken: String): AuthResponseDTO =
        client.post(url("auth/google")) {
            setBody(GoogleExchangeRequestDTO(identityToken = idToken))
        }.expect()

    suspend fun signOut() {
        client.post(url("auth/signout")) { auth() }.expectEmpty()
    }

    // -----------------------------------------------------------------
    // Sync
    // -----------------------------------------------------------------

    /**
     * GET /sync/changes?since=ISO. Used by the SyncEngine pull pass.
     * `since = null` means "give me everything"; the server treats
     * that as 1970-01-01 internally.
     */
    suspend fun syncChanges(since: String?): SyncChangesDTO =
        client.get(url("sync/changes")) {
            auth()
            since?.let { parameter("since", it) }
        }.expect()

    // -----------------------------------------------------------------
    // Workout sessions
    // -----------------------------------------------------------------

    suspend fun getWorkoutSessions(): List<WorkoutSessionDTO> =
        client.get(url("workout-sessions")) { auth() }.expect()

    suspend fun upsertWorkoutSession(dto: WorkoutSessionDTO): WorkoutSessionDTO =
        client.put(url("workout-sessions/${dto.id}")) {
            auth()
            setBody(dto)
        }.expect()

    suspend fun deleteWorkoutSession(id: String) {
        client.delete(url("workout-sessions/$id")) { auth() }.expectEmpty()
    }

    // -----------------------------------------------------------------
    // Exercises + sets (flat upsert; parent linkage via DTO field)
    // -----------------------------------------------------------------

    suspend fun upsertExerciseEntry(dto: ExerciseEntryDTO): ExerciseEntryDTO =
        client.put(url("exercise-entries/${dto.id}")) {
            auth()
            setBody(dto)
        }.expect()

    suspend fun deleteExerciseEntry(id: String) {
        client.delete(url("exercise-entries/$id")) { auth() }.expectEmpty()
    }

    suspend fun upsertWorkoutSet(dto: WorkoutSetDTO): WorkoutSetDTO =
        client.put(url("workout-sets/${dto.id}")) {
            auth()
            setBody(dto)
        }.expect()

    suspend fun deleteWorkoutSet(id: String) {
        client.delete(url("workout-sets/$id")) { auth() }.expectEmpty()
    }

    // -----------------------------------------------------------------
    // Templates
    // -----------------------------------------------------------------

    suspend fun upsertWorkoutTemplate(dto: WorkoutTemplateDTO): WorkoutTemplateDTO =
        client.put(url("workout-templates/${dto.id}")) {
            auth()
            setBody(dto)
        }.expect()

    suspend fun deleteWorkoutTemplate(id: String) {
        client.delete(url("workout-templates/$id")) { auth() }.expectEmpty()
    }

    // -----------------------------------------------------------------
    // Profile + body weight
    // -----------------------------------------------------------------

    /**
     * GET /profile -- returns null when the user has no profile row.
     * The server emits literal JSON `null` in that case; Ktor
     * decodes that to a Kotlin null when the type is nullable.
     */
    suspend fun fetchProfile(): UserProfileDTO? {
        val response = client.get(url("profile")) { auth() }
        if (!response.status.isSuccess()) throwForStatus(response)
        // Body is either a UserProfileDTO or "null" -- decode raw
        // string and let kotlinx handle the JSON null sentinel.
        val text = response.bodyAsText().trim()
        if (text == "null" || text.isEmpty()) return null
        return json.decodeFromString(UserProfileDTO.serializer(), text)
    }

    suspend fun upsertProfile(dto: UserProfileDTO): UserProfileDTO =
        client.put(url("profile")) {
            auth()
            setBody(dto)
        }.expect()

    suspend fun upsertBodyWeightEntry(dto: BodyWeightEntryDTO): BodyWeightEntryDTO =
        client.put(url("body-weight-entries/${dto.id}")) {
            auth()
            setBody(dto)
        }.expect()

    suspend fun deleteBodyWeightEntry(id: String) {
        client.delete(url("body-weight-entries/$id")) { auth() }.expectEmpty()
    }

    // -----------------------------------------------------------------
    // Coach
    // -----------------------------------------------------------------

    suspend fun coachRecommendations(
        goal: String,
        unit: String,
        forceRefresh: Boolean = false,
    ): CoachResponseDTO =
        client.post(url("coach/recommendations")) {
            auth()
            setBody(CoachRequestDTO(goal, unit, forceRefresh))
        }.expect()

    // -----------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------

    private fun url(path: String): String =
        baseUrl.trimEnd('/') + "/" + path.trimStart('/')

    private fun io.ktor.client.request.HttpRequestBuilder.auth() {
        bearer()?.let { token ->
            header(HttpHeaders.Authorization, "Bearer $token")
        }
    }

    private suspend inline fun <reified T> HttpResponse.expect(): T {
        if (!status.isSuccess()) throwForStatus(this)
        return body()
    }

    private suspend fun HttpResponse.expectEmpty() {
        if (!status.isSuccess()) throwForStatus(this)
    }

    private suspend fun throwForStatus(response: HttpResponse): Nothing {
        val raw = response.bodyAsText()
        val message = parseErrorMessage(raw) ?: raw.take(500)
        throw ApiException(response.status, message)
    }

    private fun parseErrorMessage(raw: String): String? {
        if (raw.isBlank()) return null
        return try {
            // Permissively pull "error" or "message" out of common
            // server envelopes without committing to a specific
            // schema -- the server already emits a couple of shapes
            // (zod-style and HttpError-style).
            val parsed = json.parseToJsonElement(raw)
            when {
                parsed is kotlinx.serialization.json.JsonObject -> {
                    val obj = parsed
                    obj["message"]?.toString()?.trim('"')
                        ?: obj["error"]?.toString()?.trim('"')
                }
                else -> null
            }
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        private const val TAG = "LiftingAPI"
    }
}

class ApiException(val status: HttpStatusCode, message: String) : RuntimeException(message)
