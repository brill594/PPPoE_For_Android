plugins {
    id("com.android.application")
    kotlin("android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.devtools.ksp") version "2.1.0-1.0.29" // Or the version matching your Kotlin
}

android {
    namespace = "com.brill.pppoe_controller"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.brill.pppoe_controller"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    packaging {
        resources.excludes += "META-INF/*"
    }
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.1.0")
    implementation("com.github.topjohnwu.libsu:core:5.2.2")
    implementation("com.github.topjohnwu.libsu:service:5.2.2")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-ktx:1.9.0")
    val room_version = "2.6.1" // Use the latest stable version
    implementation("androidx.room:room-runtime:$room_version")
    ksp("androidx.room:room-compiler:$room_version") // Use ksp instead of kapt if possible
    implementation("androidx.room:room-ktx:$room_version") // F
}
