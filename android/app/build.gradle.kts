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
        versionCode = 1
        versionName = "0.1.0"
    }
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
        release { if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release"); isMinifyEnabled = true; proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro") }
        // Emulator-only build: emulators lack hardware-backed keys. Never distribute this variant.
        create("qa") { initWith(getByName("debug")); applicationIdSuffix = ".qa"; versionNameSuffix = "-qa"; buildConfigField("boolean", "ALLOW_SOFTWARE_KEYSTORE", "true") }
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
}
