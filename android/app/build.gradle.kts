plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "app.passvault"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.passvault.mobile"
        minSdk = 30
        targetSdk = 36
        versionCode = 5
        versionName = "2026.10.8"
        manifestPlaceholders["appLabel"] = "PassVault"
    }
    // Instrumented tests run on an emulator, which has no hardware-backed keys, so they use the emulator-only "qa" variant.
    testBuildType = "qa"
    defaultConfig.testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    // Release signing comes only from the environment (CI secrets); no key is ever committed.
    val releaseKeystore = System.getenv("QV_KEYSTORE_FILE")
    signingConfigs {
        if (releaseKeystore != null) create("release") {
            storeFile = file(releaseKeystore); storePassword = System.getenv("QV_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("QV_KEY_ALIAS"); keyPassword = System.getenv("QV_KEY_PASSWORD")
        }
    }
    buildTypes {
        // UPDATE_CHANNEL: "none" (debug, qa: no update check), "github" (sideload APK), "play" (Google Play AAB).
        all { buildConfigField("boolean", "ALLOW_SOFTWARE_KEYSTORE", "false"); buildConfigField("String", "UPDATE_CHANNEL", "\"none\"") }
        // Own package name and label so the debug build installs next to (not over) a release build signed with a different key.
        debug { applicationIdSuffix = ".debug"; versionNameSuffix = "-debug"; manifestPlaceholders["appLabel"] = "PassVault Dev" }
        release { if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release"); isMinifyEnabled = true; proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"); buildConfigField("String", "UPDATE_CHANNEL", "\"github\"") }
        // Upload this variant to Play. It updates through Play and has no INTERNET or APK-install permission.
        create("playRelease") { initWith(getByName("release")); matchingFallbacks += listOf("release"); buildConfigField("String", "UPDATE_CHANNEL", "\"play\"") }
        // Emulator-only build: emulators lack hardware-backed keys. Never distribute this variant.
        create("qa") { initWith(getByName("debug")); applicationIdSuffix = ".qa"; versionNameSuffix = "-qa"; manifestPlaceholders["appLabel"] = "PassVault QA"; buildConfigField("boolean", "ALLOW_SOFTWARE_KEYSTORE", "true") }
    }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.12.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.12.1")
    implementation("androidx.fragment:fragment-ktx:1.8.9")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("com.goterl:lazysodium-android:5.2.0@aar")
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    // Authenticator QR scanning: on-device camera preview and decoding only (no Play services, no network).
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("com.google.zxing:core:3.5.3")
    // In-app updates: Google Play's update flow for Play installs (talks to the Play Store app, not the network).
    implementation("com.google.android.play:app-update:2.1.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("org.json:json:20250517")
}
