# Lifting — Android

The Android client for [Lifting](../README.md). Talks to the same
[Node/Express server](../server/README.md) the iOS app uses, so any
data you log on either platform shows up on the other after the next
sync.

## Stack

- **Kotlin** + **Jetpack Compose** (mirror of the iOS SwiftUI layer)
- **Room** for local persistence (mirror of SwiftData)
- **Ktor Client** for HTTP (mirror of `URLSession + Codable`)
- **kotlinx.serialization** for JSON
- **Credential Manager + Google ID** for sign-in
- **EncryptedSharedPreferences** for the session JWT (Keychain
  equivalent)
- **Vico** for charts (HistoryView's line + heatmap visualizations)

Min SDK 26 (Android 8.0+, ~95% of devices). compileSdk / targetSdk 35
(required by current AndroidX core libs and Play Store policy for new
submissions from late 2025).

## Project layout

```
android/
├─ app/
│  └─ src/main/java/com/wasatchcode/lifting/
│     ├─ data/
│     │  ├─ models/        Room entities (mirror Models.swift)
│     │  ├─ dto/           Wire DTOs (mirror DataLayer.swift)
│     │  ├─ local/         Room database + DAOs
│     │  ├─ remote/        Ktor ApiClient
│     │  └─ sync/          SyncEngine (push/pull, LWW)
│     ├─ auth/             Google sign-in + JWT storage
│     ├─ features/
│     │  ├─ home/          HomeScreen
│     │  └─ signin/        SignInScreen
│     ├─ ui/theme/         Colors + typography (mirror Theme.swift)
│     ├─ LiftingApp.kt     Process-wide singletons
│     └─ MainActivity.kt   Compose root
├─ build.gradle.kts        Top-level Gradle (Kotlin DSL)
├─ settings.gradle.kts
├─ gradle.properties
└─ gradle/libs.versions.toml   Single-source-of-truth versions
```

## What's done

This scaffold gives you a working app that:

- ✅ Builds with current AGP / Kotlin / Compose
- ✅ Persists with Room (all 7 entities mirroring iOS)
- ✅ Talks to the lifting server via a Ktor client with the same
  endpoint shapes as `LiftingAPIClient.swift`
- ✅ Signs in with Google via the modern Credential Manager API
- ✅ Pushes + pulls workout sessions / exercises / sets through
  `SyncEngine` with LWW reconciliation
- ✅ Forces dark theme matching the iOS palette
- ✅ Shows a real Home screen reading from Room

## What's stubbed (TODO)

The SyncEngine handles **sessions / exercises / sets** end-to-end.
The other tables (templates, profile, body weight) are wired into
the data layer but not yet pushed/pulled. Each is an additional
~30-line block in `SyncEngine.kt` following the existing pattern.

UI: only HomeScreen + SignInScreen exist. To reach feature parity
with iOS you'll port:

- WorkoutScreen (active session, set logging, finish flow)
- HistoryScreen (the new four-section design)
- ExerciseProgressScreen (per-exercise drilldown)
- WorkoutDetailScreen (snapshot of a finished workout)
- ProfileScreen (athlete data)
- BodyWeightLogScreen
- TemplatePickerSheet + TemplateEditorScreen
- CoachScreen (AI recommendations)
- SetLoggerSheet (the +/- weight/reps with REPS/TIME toggle)

Each is roughly a day of focused Compose work. The data layer and
sync are ready for you.

## Setup

### 1. Tooling

You need:

- **Android Studio Hedgehog (2024.1) or newer** — earlier versions
  don't ship a Kotlin compiler that matches the version catalog.
- **JDK 17** — Android Studio bundles it; from the CLI ensure
  `JAVA_HOME` points at one (`brew install --cask zulu17` works).

### 2. Google Cloud OAuth client (required for sign-in)

The Credential Manager + GoogleIdToken flow needs an OAuth 2.0 **Web
application** client ID (NOT an Android one). The same Web client ID
is what the server uses to verify the token.

If you already set up `GOOGLE_OAUTH_CLIENT_ID_IOS` for the iOS build,
**use the same Web client ID here** -- the server is configured
against that single value.

If you haven't:

1. https://console.cloud.google.com/ → APIs & Services → Credentials
2. **Create credentials → OAuth client ID → Application type: Web**
3. Copy the `Client ID`, looks like `123-abc.apps.googleusercontent.com`
4. Add it as `GOOGLE_OAUTH_CLIENT_ID_IOS` on Fly secrets (server reads
   it for token verification regardless of which client used it).

Then drop it into `android/local.properties` (gitignored):

```properties
GOOGLE_WEB_CLIENT_ID=123-abc.apps.googleusercontent.com
```

The Gradle build picks this up via `project.findProperty(...)` and
exposes it as `BuildConfig.GOOGLE_WEB_CLIENT_ID` to the runtime.

### 3. Server URL

The default server URL for **debug builds** is `http://10.0.2.2:3000`
— this is the Android emulator's loopback to the host machine, where
your local Express server is presumably running. So if you run
`npm run dev` in `../server/`, the emulator can reach it.

For a **physical device** on the same Wi-Fi as your laptop:

```bash
adb reverse tcp:3000 tcp:3000
```

That makes `http://localhost:3000` resolve from the device too.

For **release builds**, the URL is hard-coded to
`https://lifting-server.fly.dev` in `app/build.gradle.kts`. Edit
that to match your actual Fly.io app name.

### 4. Build

```bash
cd android
./gradlew assembleDebug
```

(First build downloads ~600 MB of dependencies. Be patient.)

### 5. Run

Open `android/` in Android Studio → press Run, OR from CLI:

```bash
./gradlew installDebug
adb shell am start -n com.wasatchcode.lifting/.MainActivity
```

## Day-to-day

- **Sync from server**: tap "Refresh from server" on the Home screen
  for now. Any data you logged on iOS will appear here.
- **Logcat tag**: `LiftingAPI` for HTTP traffic, `SyncEngine` for
  sync passes, `AuthManager` for sign-in flow.
- **Reset local data**: uninstall the app (the Room DB lives in app
  storage and gets purged with it). The next sign-in re-syncs from
  the server.

## Wiring future iOS features into Android

The way the codebases stay in sync without doubling the work:

1. Add the column / endpoint / business rule **server-side first**.
2. Update **Zod schemas** + Postgres + the iOS `Codable` DTOs.
3. Update the Android `kotlinx.serialization` DTOs to match (look
   in `data/dto/Dtos.kt` -- almost always a one-line addition since
   Kotlin's data classes mirror Swift structs naturally).
4. Update the Room entity in `data/models/Entities.kt` and bump the
   AppDatabase `version`.
5. Hook the field into the SyncEngine push/pull path (one line in
   `applySession`/`applyExercise`/etc., one line in `toDto()`).
6. Light it up in the UI on each platform when ready.

The wire contract is the source of truth. Both clients are
disposable around it.

## Known gotchas

- **Credential Manager requires Google Play Services.** Won't work
  on emulators without GAPI. Use a "Pixel ... API 34 with Google
  Play" image, not the bare AOSP one.
- **First build can be very slow** because of Compose compiler +
  Room KSP cold cache. Subsequent builds are ~10 seconds.
- **Room's `fallbackToDestructiveMigration()` is enabled.** Every
  schema bump nukes the local DB. Fine while you're the only user;
  swap to proper migrations before Play Store release.
- **The launcher icon is a placeholder.** Replace
  `app/src/main/res/drawable/ic_launcher_foreground.xml` with the
  generated icon from `marketing/app-store-design-prompt.md` once
  you have it.
- **No bottom-tab navigation yet.** Add via Navigation Compose when
  you port the second screen.
