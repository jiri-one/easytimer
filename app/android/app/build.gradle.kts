import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keyProperties = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
fun signingValue(property: String, environment: String): String? =
    keyProperties.getProperty(property)?.takeIf { it.isNotBlank() }
        ?: System.getenv(environment)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
val signingValues = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
val hasReleaseKey = signingValues.all { it != null }
val isTagBuild = System.getenv("GITHUB_REF_TYPE") == "tag"

if (signingValues.any { it != null } && !hasReleaseKey) {
    throw GradleException("Release signing is incomplete; provide all four properties or ANDROID_* variables.")
}
if (isTagBuild && !hasReleaseKey) {
    // A published debug-signed APK could never be updated with the release key.
    throw GradleException("Tag builds require the Android release signing key.")
}
if (hasReleaseKey && !rootProject.file(releaseStoreFile!!).isFile) {
    throw GradleException("The configured Android release keystore does not exist.")
}
if (!hasReleaseKey) {
    logger.warn("No Android release signing key configured; local release builds use the debug key.")
}

android {
    namespace = "one.jiri.easytimer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "one.jiri.easytimer"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    dependenciesInfo {
        // F-Droid cannot audit Google's encrypted dependency metadata.
        includeInApk = false
        includeInBundle = false
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
