// Top-level build file. Plugins are declared here with `apply false`
// so each module can opt in via its own `plugins { ... }` block while
// still pulling versions from the version catalog.

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.ksp) apply false
}
