import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 从 android/key.properties 读取签名信息。
// 该文件和 keystore 都在 .gitignore 里，不会进版本库。
// 文件不存在时 hasReleaseKeystore 为 false，release 会退回到 debug 签名，
// 这样在还没配签名之前 `flutter run --release` 依然能跑。
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseKeystore) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

// 目标 ABI 列表：默认只出 arm64-v8a（安装包约 28 MB，三架构通用包约 65 MB）。
//
// 第三方依赖（dartjni 等）的 jniLibs 不受 `flutter build --target-platform`
// 约束，不显式限定就会残留 32 位 / x86 的 so，让 APK 误声明支持这些架构 ——
// 装得上却启动不了。
//
// 要出多架构包时只改这一行，例如：
//   setOf("arm64-v8a", "armeabi-v7a")
// 下面的 ndk 过滤和 packaging 排除都以它为准，不用改别处。
val targetAbis: Set<String> = setOf("arm64-v8a")

// Android 认识的 ABI 目录名；不在 [targetAbis] 里的会在打包阶段被排除。
val knownAbiDirs = listOf(
    "armeabi", "armeabi-v7a", "arm64-v8a",
    "x86", "x86_64", "mips", "mips64",
)

android {
    namespace = "com.example.tbank"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 应用在设备/商店上的唯一身份，一旦发布就不可再改。
        // 注意：上面的 namespace 仍是 com.example.tbank——它只决定代码包结构，
        // 与上架身份无关，保持不动就不必搬动 MainActivity.kt。
        applicationId = "com.zhaotr.tbank"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只编目标 ABI 的原生库（默认 arm64-v8a，见文件头的 targetAbis）
        ndk {
            abiFilters.addAll(targetAbis)
        }
    }

    // 预编译 so（第三方 aar / pub 包里的 jniLibs）不受 ndk.abiFilters 约束，
    // 必须在打包阶段排除，否则 APK 会误声明支持 32 位和 x86 —— 装得上却起不来。
    packaging {
        jniLibs {
            excludes += knownAbiDirs
                .filter { it !in targetAbis }
                .map { "lib/$it/**" }
                .toSet()
        }
    }

    signingConfigs {
        // 只有 key.properties 存在时才创建正式签名配置
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // storeFile 相对 android/app 目录解析
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // 配了 key.properties 就用正式签名，否则退回 debug 签名
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 应用内更新用 FileProvider 把缓存的 APK 交给系统安装器
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
