import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (storeFile, storePassword, keyAlias, keyPassword)
// or env MELSI_KEYSTORE / MELSI_KEYSTORE_PASSWORD / MELSI_KEY_ALIAS / MELSI_KEY_PASSWORD.
// Falls back to the debug key so `flutter build apk --release` always works.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}

fun signingValue(prop: String, env: String): String? =
    keyProperties.getProperty(prop)?.takeIf { it.isNotBlank() }
        ?: System.getenv(env)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("storeFile", "MELSI_KEYSTORE")
val hasReleaseSigning = releaseStoreFile != null && rootProject.file(releaseStoreFile).exists()

// libbox.aar (sing-box libbox + melsicore) is produced by scripts/build-libbox.sh.
val libboxAar = file("libs/libbox.aar")

android {
    namespace = "app.melsi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.melsi"
        // Flutter 3.47 minimum; sing-box-for-android also uses 24 for its main flavor.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. With --split-per-abi Flutter adds 1000 * ABI.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = signingValue("storePassword", "MELSI_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "MELSI_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "MELSI_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "release" else "debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    packaging {
        jniLibs {
            // Same as sing-box-for-android: extract the (large) Go .so on install.
            useLegacyPackaging = true
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
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

dependencies {
    implementation(files("libs/libbox.aar"))
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
}

tasks.named("preBuild") {
    doFirst {
        if (!libboxAar.exists()) {
            throw GradleException(
                "Missing ${libboxAar.path}.\n" +
                    "Build it first: scripts/build-libbox.sh android " +
                    "(gomobile bind of sing-box libbox + melsicore, see docs/CONTRACT.md §5).",
            )
        }
    }
}
