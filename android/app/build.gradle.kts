plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

// 固定签名密钥：从 android/key.properties 读取（由 CI 从 GitHub Secrets 写入，
// 或本地放一份）。这样每次发版的 APK 都用同一把密钥签名，覆盖安装才不会报
// "签名不一致"。CI 里没有 key.properties 时退回 debug 密钥，本地 `flutter run
// --release` 照常可用。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "app.wisp.wisp"
    // flutter_plugin_android_lifecycle 要求 compileSdk >= 36，固定高于 Flutter 默认值。
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.wisp.wisp"
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
    }

    // 只有存在 key.properties 时才创建"release"签名配置，避免本地无密钥时
    // 在配置阶段读取 null 直接抛 NPE。
    if (keystorePropertiesFile.exists()) {
        // 注意：这里必须用 rootProject.file()，不能用 file()。
        // file() 相对的是 app 模块目录（android/app/），而 key.properties 与
        // 密钥库都放在 android/ 下——用 file() 会去 android/app/ 找一个不存在的
        // 文件，报的却是含混的 "Keystore file not found"（1.0.20 首次带签名
        // 发版就栽在这）。
        val storeFileValue = keystoreProperties["storeFile"] as String
        val resolvedStore = rootProject.file(storeFileValue)
        require(resolvedStore.exists()) {
            "key.properties 里的 storeFile 指向的密钥库不存在：${resolvedStore.absolutePath}"
        }
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = resolvedStore
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 时用固定签名密钥（CI / 正式发布），
            // 否则退回 debug 密钥（本地无密钥时 flutter run --release 仍可跑）。
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
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

dependencies {
    // MainActivity 用 androidx FileProvider 生成 content:// URI：
    // 分区存储下安装 APK / 用第三方应用打开附件都需要它。
    implementation("androidx.core:core-ktx:1.13.1")
}
