plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.aicreatorhub.ai_creator_hub"

    // compileSdk / minSdk / targetSdk / ndkVersion / versionCode / versionName are
    // all supplied by the Flutter Gradle plugin based on the Flutter SDK in use
    // (see https://flutter.dev/to/review-gradle-config), so they automatically
    // track whatever Flutter 3.35.x (or later) expects — no hardcoded numbers to
    // fall out of date here.
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.aicreatorhub.ai_creator_hub"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO (Phase 5): replace with a real upload keystore before
            // publishing to the Play Store — see docs.flutter.dev/deployment/android.
            // Signing with the debug keys for now so `flutter build apk --release`
            // (and the CI workflow) succeed out of the box.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
