import com.android.build.api.artifact.SingleArtifact
import com.android.build.api.variant.BuiltArtifactsLoader
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}
// Debug builds can update from a server on your LAN (scripts/serve-dev-update.sh). The host comes from the
// gitignored .env at the repository root (or the environment), so no address is ever committed.
val dotEnv = providers.fileContents(layout.projectDirectory.file("../../.env")).asText.orNull.orEmpty()
    .lineSequence().map(String::trim).filter { it.isNotEmpty() && !it.startsWith("#") && "=" in it }
    .associate { line -> line.substringBefore("=").removePrefix("export ").trim() to line.substringAfter("=").substringBefore(" #").trim().trim('"', '\'') }
fun devSetting(name: String) = providers.environmentVariable(name).orNull ?: dotEnv[name]
val devUpdateHost = devSetting("PASSVAULT_DEV_UPDATE_HOST")?.takeIf(String::isNotBlank)?.also {
    require(Regex("^[A-Za-z0-9.-]+$").matches(it)) { "PASSVAULT_DEV_UPDATE_HOST must be an IPv4 address or host name" }
}
val devUpdatePort = (devSetting("PASSVAULT_DEV_UPDATE_PORT") ?: "8766").also {
    require(it.toIntOrNull() in 1..65535) { "PASSVAULT_DEV_UPDATE_PORT must be a port number" }
}
android {
    namespace = "app.passvault"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.passvault.mobile"
        minSdk = 30
        targetSdk = 36
        versionCode = 9
        versionName = "2026.10.30"
        manifestPlaceholders["appLabel"] = "PassVault"
        buildConfigField("String", "DEV_UPDATE_URL", "\"\"")
    }
    // Instrumented tests run on an emulator, which has no hardware-backed keys, so they use the emulator-only "qa" variant.
    testBuildType = "qa"
    defaultConfig.testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    buildFeatures { compose = true; buildConfig = true }
    // Only the app's own languages. Libraries ship ~80 translations each; the Chinese forms they use (zh-rCN/TW/HK) are kept so
    // system pieces such as the date picker and the biometric prompt stay translated.
    androidResources { localeFilters += listOf("en", "b+zh+Hans", "b+zh+Hant", "zh-rCN", "zh-rTW", "zh-rHK") }
    // Code and native libraries are stored compressed: about half the APK download, unpacked once at install.
    packaging {
        jniLibs { useLegacyPackaging = true }; dex { useLegacyPackaging = true }
        // BouncyCastle's data files (post-quantum tables, X.509 messages); the KeePass import uses only Argon2, ChaCha20 and Salsa20.
        resources { excludes += "org/bouncycastle/**" }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    // Release signing comes only from the environment (set by scripts/_signing-common.sh); no key is ever committed.
    val releaseKeystore = System.getenv("PASSVAULT_KEYSTORE_FILE")
    signingConfigs {
        if (releaseKeystore != null) create("release") {
            storeFile = file(releaseKeystore); storePassword = System.getenv("PASSVAULT_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("PASSVAULT_KEY_ALIAS"); keyPassword = System.getenv("PASSVAULT_KEY_PASSWORD")
        }
    }
    buildTypes {
        // UPDATE_CHANNEL: "none" (qa, and debug without a LAN server: no update check), "lan" (debug with
        // PASSVAULT_DEV_UPDATE_HOST), "github" (sideload APK), "play" (Google Play AAB).
        // REQUIRE_UNLOCKED_DEVICE: Keystore keys refuse to work while the phone is locked. Only qa (emulator tests) leaves it off: CI
        // emulators cannot be unlocked reliably, and the tests only need a secure lock screen to exist.
        all { buildConfigField("boolean", "ALLOW_SOFTWARE_KEYSTORE", "false"); buildConfigField("boolean", "REQUIRE_UNLOCKED_DEVICE", "true"); buildConfigField("String", "UPDATE_CHANNEL", "\"none\"") }
        // Own package name and label so the debug build installs next to (not over) a release build signed with a different key.
        debug {
            applicationIdSuffix = ".debug"; versionNameSuffix = "-debug"; manifestPlaceholders["appLabel"] = "PassVault Dev"
            if (devUpdateHost != null) {
                buildConfigField("String", "UPDATE_CHANNEL", "\"lan\"")
                buildConfigField("String", "DEV_UPDATE_URL", "\"http://$devUpdateHost:$devUpdatePort/\"")
            }
        }
        release {
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true; isShrinkResources = true; proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Phones are ARM; x86 is only for emulators, which use the debug and qa builds (they keep every ABI).
            ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
            buildConfigField("String", "UPDATE_CHANNEL", "\"github\"")
        }
        // Upload this variant to Play. It updates through Play and has no INTERNET or APK-install permission.
        create("playRelease") { initWith(getByName("release")); matchingFallbacks += listOf("release"); buildConfigField("String", "UPDATE_CHANNEL", "\"play\"") }
        // Emulator-only build: emulators lack hardware-backed keys. Never distribute this variant.
        create("qa") { initWith(getByName("debug")); applicationIdSuffix = ".qa"; versionNameSuffix = "-qa"; manifestPlaceholders["appLabel"] = "PassVault QA"; buildConfigField("boolean", "ALLOW_SOFTWARE_KEYSTORE", "true")
            buildConfigField("boolean", "REQUIRE_UNLOCKED_DEVICE", "false"); buildConfigField("String", "UPDATE_CHANNEL", "\"none\""); buildConfigField("String", "DEV_UPDATE_URL", "\"\"") }
    }
    // Instrumented tests open transfers written by the iOS app (fixtures/transfer).
    sourceSets.getByName("androidTest") { assets.srcDir("../../fixtures/transfer") }
    // Network, install permission and FileProvider exist in debug only when a LAN update server is set.
    if (devUpdateHost != null) sourceSets.getByName("debug") {
        manifest.srcFile("src/lanUpdate/AndroidManifest.xml")
        res.srcDir("src/lanUpdate/res")
    }
}
androidComponents.onVariants(androidComponents.selector().withBuildType("debug")) { variant ->
    // Every debug build, with or without a LAN server, must count as newer than the installed one: seconds since 2026-01-01 UTC
    // (earlier LAN builds counted minutes, which are far smaller, so they still upgrade; two builds a minute apart no longer collide).
    val stamp = (System.currentTimeMillis() / 1000 - 1_767_225_600).toInt()
    variant.outputs.forEach { it.versionCode.set(stamp) }
    if (devUpdateHost == null) return@onVariants
    val network = tasks.register<LanNetworkConfig>("${variant.name}LanNetworkConfig") { host.set(devUpdateHost) }
    variant.sources.res?.addGeneratedSourceDirectory(network, LanNetworkConfig::outputDir)
    val publish = tasks.register<PublishLanUpdate>("${variant.name}PublishLanUpdate") {
        apkFolder.set(variant.artifacts.get(SingleArtifact.APK))
        loader.set(variant.artifacts.getBuiltArtifactsLoader())
        outputDir.set(rootProject.layout.projectDirectory.dir("dist/dev-update"))
    }
    tasks.matching { it.name == "assemble${variant.name.replaceFirstChar(Char::uppercase)}" }.configureEach { finalizedBy(publish) }
}

/** Lets the debug app use plain HTTP to the LAN update host and nowhere else. */
abstract class LanNetworkConfig : DefaultTask() {
    @get:Input abstract val host: Property<String>
    @get:OutputDirectory abstract val outputDir: DirectoryProperty
    @TaskAction fun write() {
        outputDir.get().file("xml/lan_update_network.xml").asFile.apply { parentFile.mkdirs() }.writeText("""
            <network-security-config>
                <domain-config cleartextTrafficPermitted="true"><domain includeSubdomains="false">${host.get()}</domain></domain-config>
            </network-security-config>
        """.trimIndent())
    }
}

/** Copies the debug APK to android/dist/dev-update with the latest.json and SHA256SUMS that the app reads. */
abstract class PublishLanUpdate : DefaultTask() {
    @get:InputFiles abstract val apkFolder: DirectoryProperty
    @get:Internal abstract val loader: Property<BuiltArtifactsLoader>
    @get:OutputDirectory abstract val outputDir: DirectoryProperty
    @TaskAction fun publish() {
        val built = loader.get().load(apkFolder.get()) ?: throw GradleException("No debug APK was built")
        val output = built.elements.single()
        val code = output.versionCode ?: throw GradleException("The debug APK has no version code")
        val directory = outputDir.get().asFile.apply { mkdirs() }
        val name = "PassVault-debug-$code.apk"
        val apk = File(output.outputFile).copyTo(File(directory, name), overwrite = true)
        val sha = MessageDigest.getInstance("SHA-256").digest(apk.readBytes()).joinToString("") { "%02x".format(it) }
        File(directory, "PassVault-debug-$code.SHA256SUMS").writeText("$sha  $name\n")
        val json = """{"versionCode":$code,"versionName":"${output.versionName.orEmpty()}","apk":"$name","size":${apk.length()}}"""
        File(directory, "latest.json.part").apply { writeText(json + "\n") }.renameTo(File(directory, "latest.json"))
        // Only now drop older builds, so latest.json never names a file that is missing.
        directory.listFiles()?.filter { it.name.startsWith("PassVault-debug-") && !it.name.startsWith("PassVault-debug-$code.") }
            ?.forEach { it.delete() }
        logger.lifecycle("LAN update: android/dist/dev-update/$name (versionCode $code)")
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
    // KeePass (.kdbx) import: Argon2d/Argon2id, ChaCha20 and Salsa20 (libsodium has Argon2id only). R8 keeps only the classes used.
    implementation("org.bouncycastle:bcprov-jdk18on:1.81")
    // In-app updates: Google Play's update flow for Play installs (talks to the Play Store app, not the network).
    implementation("com.google.android.play:app-update:2.1.0")
    // App password guessability (zxcvbn): dictionaries, keyboard patterns, dates and l33t, all bundled in the jar; nothing is sent anywhere.
    implementation("com.nulab-inc:zxcvbn:1.9.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("org.json:json:20250517")
}

// AgeInteropTest runs against the official age tools when AGE_BIN_DIR points at them (CI); rerun the tests when that changes.
tasks.withType<Test>().configureEach {
    inputs.property("ageBinDir", providers.environmentVariable("AGE_BIN_DIR").orElse(""))
    inputs.property("ageInteropRequired", providers.environmentVariable("AGE_INTEROP_REQUIRED").orElse(""))
}
