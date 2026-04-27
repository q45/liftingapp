// App module build file.
//
// `applicationId = com.wasatchcode.lifting` matches the iOS bundle ID.
// minSdk 26 is the right floor for Compose: it gives us modern
// permission flows, foreground services, vector drawables, and tile
// rendering without the older-API workarounds. ~95% of devices.

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

android {
    namespace = "com.wasatchcode.lifting"
    // compileSdk 35 is required by `androidx.core 1.15.x` which is
    // pulled in transitively by the modern Compose / lifecycle stack.
    // Also matches Google Play's policy floor for new app submissions
    // from late 2025 onward, so we'd be bumping it for release anyway.
    compileSdk = 35

    defaultConfig {
        applicationId = "com.wasatchcode.lifting"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        debug {
            // Point at localhost from a real device by setting up
            // adb reverse, or override BuildConfig.SERVER_URL in
            // local.properties later.
            buildConfigField(
                "String",
                "DEFAULT_SERVER_URL",
                "\"http://10.0.2.2:3000\"",
            )
            buildConfigField(
                "String",
                "GOOGLE_WEB_CLIENT_ID",
                "\"${project.findProperty("GOOGLE_WEB_CLIENT_ID") ?: ""}\"",
            )
            // Local dev quality-of-life: skip the Google Sign-In flow
            // and let the server's DEV_BYPASS_AUTH escape hatch route
            // unauthenticated requests to the legacy user. NEVER
            // shipped in release. Server must be started with
            // DEV_BYPASS_AUTH=1 in its env for this to work.
            buildConfigField("boolean", "DEV_BYPASS_AUTH", "true")
        }
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // For release: bake your prod URL here, or override at
            // CI time. The default points to your future Fly app.
            buildConfigField(
                "String",
                "DEFAULT_SERVER_URL",
                "\"https://lifting-server.fly.dev\"",
            )
            buildConfigField(
                "String",
                "GOOGLE_WEB_CLIENT_ID",
                "\"${project.findProperty("GOOGLE_WEB_CLIENT_ID") ?: ""}\"",
            )
            // Hard off in release. Defense in depth -- the AuthManager
            // also gates on this flag, but baking it false here means
            // a misconfigured server can't accidentally let a
            // production build skip sign-in.
            buildConfigField("boolean", "DEV_BYPASS_AUTH", "false")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources.excludes += setOf(
            "META-INF/AL2.0",
            "META-INF/LGPL2.1",
            "META-INF/*.kotlin_module",
        )
    }
}

dependencies {
    // Compose
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui)
    implementation(libs.compose.runtime)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.activity.compose)
    implementation(libs.navigation.compose)

    implementation(libs.androidx.core.ktx)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)

    // Room
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)

    // Networking
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.android)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.client.logging)
    implementation(libs.ktor.serialization.kotlinx.json)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    // Storage
    implementation(libs.datastore.preferences)
    implementation(libs.security.crypto)

    // Google Sign-In via Credential Manager
    implementation(libs.credentials)
    implementation(libs.credentials.play.services.auth)
    implementation(libs.googleid)

    // Charts (history view)
    implementation(libs.vico.compose.m3)
}
