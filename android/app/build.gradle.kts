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
        versionCode = 2
        versionName = "2026.9.30"
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
        all { buildConfigField("boolean", "ALLOW_SOFTWARE_KEYSTORE", "false") }
        // Own package name and label so the debug build installs next to (not over) a release build signed with a different key.
        debug { applicationIdSuffix = ".debug"; versionNameSuffix = "-debug"; manifestPlaceholders["appLabel"] = "PassVault Dev" }
        release { if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release"); isMinifyEnabled = true; proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro") }
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
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("org.json:json:20250517")
}
