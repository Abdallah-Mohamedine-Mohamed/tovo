import org.jetbrains.kotlin.gradle.dsl.JvmTarget

group = "com.tovoapp.suivi"
version = "1.0"

plugins {
    id("com.android.library")
    id("kotlin-android")
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.fromTarget(JavaVersion.VERSION_17.toString())
    }
}

android {
    namespace = "com.tovoapp.suivi"
    // Android 16 (API 36) : Notification.ProgressStyle et les notifications
    // promues (« Live Updates »). Le code se protège pour les versions
    // antérieures.
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
    }
}

dependencies {
    implementation("androidx.core:core:1.13.1")
}
