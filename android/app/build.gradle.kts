import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")

    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystorePropertiesFile = rootProject.file("key.properties")
val releaseKeystoreProperties = Properties().apply {
    if (releaseKeystorePropertiesFile.isFile) {
        releaseKeystorePropertiesFile.inputStream().use(::load)
    }
}

val androidAbis = listOf("arm64-v8a", "armeabi-v7a")
val splitPerAbi = (findProperty("split-per-abi") as? String)?.toBoolean() == true
val generatedXrayJniLibs = layout.buildDirectory.dir("generated/xrayJniLibs")
val prepareXrayJniLibs by tasks.registering(Sync::class) {
    into(generatedXrayJniLibs)
    androidAbis.forEach { abi ->
        from(rootProject.projectDir.resolve("../assets/cores/android/$abi/xray")) {
            into(abi)
            rename { "libxray.so" }
        }
    }
}

android {
    namespace = "com.example.entropy_vpn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.0.13004108"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {

        applicationId = "com.entropyvpn.app"


        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (splitPerAbi) {
        splits {
            abi {
                isEnable = true
                reset()
                include(*androidAbis.toTypedArray())
                isUniversalApk = false
            }
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = releaseKeystoreProperties.getProperty("keyAlias")
            keyPassword = releaseKeystoreProperties.getProperty("keyPassword")
            storePassword = releaseKeystoreProperties.getProperty("storePassword")
            releaseKeystoreProperties.getProperty("storeFile")?.let {
                storeFile = rootProject.file(it)
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libxray.so"
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir("src/main/jniLibs")
            jniLibs.srcDir(generatedXrayJniLibs)
        }
    }

}

tasks.configureEach {
    if (name != "prepareXrayJniLibs" && (name.contains("JniLib") || name.contains("NativeLib"))) {
        dependsOn(prepareXrayJniLibs)
    }
}

val copyReleaseApksForFlutter by tasks.registering(Copy::class) {
    val flutterApkDir = layout.buildDirectory.dir("outputs/flutter-apk")

    doFirst {
        delete(
            flutterApkDir.get().file("app-release.apk"),
            flutterApkDir.get().file("app-release.apk.sha1"),
            flutterApkDir.get().file("entropyvpn.apk"),
            flutterApkDir.get().file("entropyvpn-arm64-v8a.apk"),
            flutterApkDir.get().file("entropyvpn-armeabi-v7a.apk"),
        )
    }

    into(flutterApkDir)

    from(layout.buildDirectory.dir("outputs/apk/release")) {
        include("*arm64-v8a*.apk")
        rename { "entropyvpn-arm64-v8a.apk" }
    }
    from(layout.buildDirectory.dir("outputs/apk/release")) {
        include("*armeabi-v7a*.apk")
        rename { "entropyvpn-armeabi-v7a.apk" }
    }
}

tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy(copyReleaseApksForFlutter)
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.17.0")
    implementation(files("libs/libbox.aar"))
}
