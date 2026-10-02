plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val updateKeystorePath = System.getenv("HAOXIGUAN_UPDATE_KEYSTORE")
val updateKeystoreFile = updateKeystorePath?.let { file(it) }?.takeIf { it.isFile }
val updateStorePassword = System.getenv("HAOXIGUAN_UPDATE_STORE_PASSWORD")
val updateKeyAlias = System.getenv("HAOXIGUAN_UPDATE_KEY_ALIAS")
val updateKeyPassword = System.getenv("HAOXIGUAN_UPDATE_KEY_PASSWORD")
val hasReleaseSigning = updateKeystoreFile != null && !updateStorePassword.isNullOrEmpty() &&
    !updateKeyAlias.isNullOrEmpty() && !updateKeyPassword.isNullOrEmpty()

// Release builds never fall back to a machine's unrelated debug certificate.
// Generic assemble tasks are covered as well as explicit assembleRelease.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project.path == ":app" && it.name.contains("Release") }) {
        check(hasReleaseSigning) {
            "Release signing is required. Set HAOXIGUAN_UPDATE_KEYSTORE, " +
                "HAOXIGUAN_UPDATE_STORE_PASSWORD, HAOXIGUAN_UPDATE_KEY_ALIAS and " +
                "HAOXIGUAN_UPDATE_KEY_PASSWORD; verify the existing install certificate first."
        }
    }
}

android {
    namespace = "com.haoxiguan.haoxiguan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.haoxiguan.haoxiguan"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        multiDexEnabled = true
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("update") {
                storeFile = updateKeystoreFile
                storePassword = updateStorePassword
                keyAlias = updateKeyAlias
                keyPassword = updateKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("update")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
