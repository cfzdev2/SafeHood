import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val xmProperties = Properties().apply {
    val source = rootProject.file("xm-sdk.properties")
    if (source.exists()) source.inputStream().use { load(it) }
}
val xmEnabled = xmProperties.getProperty("enabled", "false").toBoolean()
if (xmEnabled) {
    for (key in listOf("uuid", "appKey", "appSecret", "moveCard")) {
        require(!xmProperties.getProperty(key).isNullOrBlank()) {
            "Missing XM SDK configuration: $key. See docs/xm_camera_integration.md"
        }
    }
}
fun quotedXm(value: String): String = "\"" + value.replace("\\", "\\\\")
    .replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r") + "\""

repositories {
    if (xmEnabled) maven { url = uri("https://repo.jftechsoft.com/repository/maven-releases/") }
}

android {
    namespace = "com.safehood.securityapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    buildFeatures { buildConfig = true }
    if (xmEnabled) sourceSets.getByName("main").java.srcDir("src/xm/java")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.safehood.securityapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "XM_APP_UUID", quotedXm(xmProperties.getProperty("uuid", "")))
        buildConfigField("String", "XM_APP_KEY", quotedXm(xmProperties.getProperty("appKey", "")))
        buildConfigField("String", "XM_APP_SECRET", quotedXm(xmProperties.getProperty("appSecret", "")))
        buildConfigField("int", "XM_APP_MOVECARD", if (xmEnabled)
            xmProperties.getProperty("moveCard").toInt().toString() else "0")
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    if (xmEnabled) {
        // FunSDK's POM does not declare its runtime dependencies.
        implementation("com.jftechsoft.funsdk:funsdk:5.1.4")
        implementation("io.github.xmcamera:uilibrary:2.1")
        implementation("com.alibaba:fastjson:1.2.83_noneautotype")
        implementation("com.google.code.gson:gson:2.10.1")
        implementation("org.greenrobot:eventbus:3.2.0")
        implementation("com.squareup.okhttp3:okhttp:4.12.0")
        implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
        implementation("org.apache.commons:commons-lang3:3.18.0")
        implementation("com.blankj:utilcodex:1.31.0")
        implementation("androidx.appcompat:appcompat:1.7.0")
        implementation("com.google.android.material:material:1.12.0")
    }
    implementation("androidx.media3:media3-exoplayer:1.9.2")
    implementation("androidx.media3:media3-exoplayer-rtsp:1.9.2")
    val firebaseSdkVersion = rootProject.findProperty("FirebaseSDKVersion")
        ?: rootProject.project(":firebase_core").property("FirebaseSDKVersion")
    implementation(platform("com.google.firebase:firebase-bom:$firebaseSdkVersion"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.firebase:firebase-functions")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

flutter {
    source = "../.."
}
