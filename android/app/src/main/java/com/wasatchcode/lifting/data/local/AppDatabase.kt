package com.wasatchcode.lifting.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.wasatchcode.lifting.data.models.BodyWeightEntryEntity
import com.wasatchcode.lifting.data.models.ExerciseEntryEntity
import com.wasatchcode.lifting.data.models.TemplateExerciseEntity
import com.wasatchcode.lifting.data.models.UserProfileEntity
import com.wasatchcode.lifting.data.models.WorkoutSessionEntity
import com.wasatchcode.lifting.data.models.WorkoutSetEntity
import com.wasatchcode.lifting.data.models.WorkoutTemplateEntity

/**
 * Room database aggregator. Single source of truth for the local
 * schema; KSP generates the implementation at build time.
 *
 * Versioning policy: bump `version` on every schema change. For
 * additive-only changes (new column, new table) we use
 * `fallbackToDestructiveMigrationOnDowngrade()` + the implicit
 * migration -- room handles `ADD COLUMN` for nullable fields when
 * declared in the entity. For destructive migrations, write an
 * explicit Migration object and add it to `addMigrations(...)`.
 *
 * For the dogfood phase we also enable
 * `fallbackToDestructiveMigration()` -- every schema bump nukes the
 * local DB and re-syncs from the server. SwiftData's "self-healing
 * on schema mismatch" path on iOS does the same thing.
 */
@Database(
    entities = [
        WorkoutSessionEntity::class,
        ExerciseEntryEntity::class,
        WorkoutSetEntity::class,
        WorkoutTemplateEntity::class,
        TemplateExerciseEntity::class,
        UserProfileEntity::class,
        BodyWeightEntryEntity::class,
    ],
    version = 1,
    exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun sessions(): WorkoutSessionDao
    abstract fun exercises(): ExerciseEntryDao
    abstract fun sets(): WorkoutSetDao
    abstract fun templates(): WorkoutTemplateDao
    abstract fun templateExercises(): TemplateExerciseDao
    abstract fun profile(): UserProfileDao
    abstract fun bodyWeights(): BodyWeightEntryDao

    companion object {
        @Volatile
        private var instance: AppDatabase? = null

        /**
         * Lazy singleton. Mirrors the `liftingApp.swift` shared
         * ModelContainer pattern -- one DB per process, lifetime
         * matches the app's. We make it volatile so the first
         * access is well-ordered across threads.
         */
        fun get(context: Context): AppDatabase {
            instance?.let { return it }
            return synchronized(this) {
                instance ?: Room
                    .databaseBuilder(
                        context.applicationContext,
                        AppDatabase::class.java,
                        "lifting.db",
                    )
                    // Acceptable for the dogfood / pre-launch phase:
                    // the server holds the canonical copy and a fresh
                    // pull rehydrates everything. Replace with proper
                    // migrations once you have real users.
                    .fallbackToDestructiveMigration()
                    .build()
                    .also { instance = it }
            }
        }
    }
}
