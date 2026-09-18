import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. Two ways to supply the key, neither of them committed:
//
//   * locally — android/key.properties (see tool/make-keystore.sh);
//   * in CI    — the ANDROID_KEYSTORE_* environment variables.
//
// When neither is present the release build falls back to the debug key, so
// `flutter build apk --release` keeps working on a fresh clone. Such an APK is
// fine for testing and must never be published.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

fun signingValue(propertyKey: String, envKey: String): String? =
    keystoreProperties.getProperty(propertyKey) ?: System.getenv(envKey)

// A relative storeFile is resolved against android/, so key.properties stays
// portable. CI passes an absolute path instead and is used as given. Anything
// else — a shell-style /d/... path from Git Bash, say — would not resolve here,
// and silently falling back to the debug key is exactly the trap this avoids.
val releaseKeystore: File? = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
    ?.takeIf { it.isNotBlank() }
    ?.let { path ->
        val candidate = File(path)
        if (candidate.isAbsolute) candidate else rootProject.file(path)
    }
val hasReleaseKey = releaseKeystore?.exists() == true

if (releaseKeystore != null && !hasReleaseKey) {
    logger.warn("Release keystore configured but not found at ${releaseKeystore.absolutePath}")
}

android {
    namespace = "io.github.ialakey.anipocket"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.ialakey.anipocket"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = releaseKeystore!!
                storePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "No release keystore found — signing with the debug key. " +
                        "Do not publish this APK."
                )
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
