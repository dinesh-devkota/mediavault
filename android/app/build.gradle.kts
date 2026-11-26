import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

abstract class BundlePrivacyPolicy : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val policyFile: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun bundlePolicy() {
        policyFile.get().asFile.copyTo(outputDirectory.file("PRIVACY.md").get().asFile, overwrite = true)
    }
}

val bundlePrivacyPolicy = tasks.register<BundlePrivacyPolicy>("bundlePrivacyPolicy") {
    policyFile.set(rootProject.layout.projectDirectory.file("../docs/PRIVACY.md"))
    outputDirectory.set(layout.buildDirectory.dir("generated/assets/privacyPolicy"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(bundlePrivacyPolicy, BundlePrivacyPolicy::outputDirectory)
    }
}

val nfsDevelopmentLibraries = providers.gradleProperty("cinevault.nfsDevelopmentLibs").orNull

val oneDriveClientId = providers.gradleProperty("mediavault.oneDriveClientId").orElse("").get().also {
    require(it.isEmpty() || it.matches(Regex("[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"))) {
        "mediavault.oneDriveClientId must be a public Microsoft Entra application UUID."
    }
}

// Signing is opt-in; ordinary release builds produce an unsigned community bundle.
val releaseSigningEnabled = when (providers.gradleProperty("cinevault.releaseSigning").orNull) {
    null, "false" -> false
    "true" -> true
    else -> throw GradleException("cinevault.releaseSigning must be true or false.")
}

android {
    namespace = "com.dineshdevkota.cinevault"
    compileSdk = 36
    sourceSets.named("androidTest") { assets.srcDir(rootProject.file("../CineVaultTests/Fixtures")) }

    defaultConfig {
        applicationId = "com.dineshdevkota.cinevault"
        minSdk = 22
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("boolean", "NFS_DEVELOPMENT_ENABLED", "false")
        buildConfigField("String", "ONEDRIVE_CLIENT_ID", "\"$oneDriveClientId\"")
        versionCode = providers.gradleProperty("cinevault.versionCode").orNull?.toInt() ?: 7
        versionName = providers.gradleProperty("cinevault.versionName").orNull ?: "1.5.0"
    }

    sourceSets.named("androidTest") {
        assets.srcDir("../../CineVaultTests/Fixtures")
    }

    nfsDevelopmentLibraries?.let { path ->
        val libraries = file(path)
        require(libraries.isDirectory) { "Provide the jniLibs directory from build_android_nfs.py." }
        sourceSets.named("debug") { jniLibs.srcDir(libraries) }
        sourceSets.named("androidTest") { java.srcDir("src/nfsDevelopmentTest/kotlin") }
    }

    if (releaseSigningEnabled) {
        val signingEnvironment = listOf(
            "CINEVAULT_KEYSTORE_PATH",
            "CINEVAULT_STORE_PASSWORD",
            "CINEVAULT_KEY_ALIAS",
            "CINEVAULT_KEY_PASSWORD",
        ).associateWith { providers.environmentVariable(it).orNull }
        val missing = signingEnvironment.filterValues { it.isNullOrBlank() }.keys
        if (missing.isNotEmpty()) {
            throw GradleException("Release signing requires environment variables: ${missing.joinToString()}")
        }
        val signingValues = signingEnvironment.mapValues { it.value!! }
        val keystore = file(signingValues.getValue("CINEVAULT_KEYSTORE_PATH"))
        if (!keystore.isFile || !keystore.canRead()) {
            throw GradleException("CINEVAULT_KEYSTORE_PATH must point to a readable keystore file.")
        }
        signingConfigs.create("release") {
            storeFile = keystore
            storePassword = signingValues.getValue("CINEVAULT_STORE_PASSWORD")
            keyAlias = signingValues.getValue("CINEVAULT_KEY_ALIAS")
            keyPassword = signingValues.getValue("CINEVAULT_KEY_PASSWORD")
        }
    }

    buildTypes {
        debug {
            if (nfsDevelopmentLibraries != null) buildConfigField("boolean", "NFS_DEVELOPMENT_ENABLED", "true")
        }
        release {
            // smbj pulls in BouncyCastle/Kerberos classes that R8 cannot shrink safely.
            isMinifyEnabled = false
            if (releaseSigningEnabled) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += setOf(
            "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
            "META-INF/DEPENDENCIES",
            "META-INF/INDEX.LIST",
        )
    }

    lint {
        abortOnError = true
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion", "OldTargetApi")
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.exifinterface:exifinterface:1.4.2")
    // Already part of SMBJ's runtime; explicitly use its portable PBKDF2 on Fire OS 5/6.
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")
    implementation(project(":core"))
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.tv.material)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)
    implementation(libs.smbj)
    implementation(libs.dcerpc) {
        exclude(group = "com.hierynomus", module = "smbj")
        exclude(group = "org.bouncycastle", module = "bcprov-jdk15on")
    }
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.hls)
    implementation(libs.media3.datasource.okhttp)
    implementation(libs.media3.ui)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.okhttp)
    implementation(libs.zxing)
    testImplementation(libs.junit)
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    androidTestImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
    androidTestImplementation(libs.androidx.test.uiautomator)
}
