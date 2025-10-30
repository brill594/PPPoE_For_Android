import java.util.Properties
import java.io.File



// 2) 读取 flutter.sdk，并把 Flutter 的 Gradle 工程作为 composite build 注入
val props = Properties()
val localPropsFile = File(settingsDir, "local.properties")
if (localPropsFile.exists()) {
    localPropsFile.inputStream().use { props.load(it) }
}
val flutterSdkPath = props.getProperty("flutter.sdk")
    ?: System.getenv("FLUTTER_ROOT")
    ?: throw GradleException(
        "Cannot locate Flutter SDK. Set `flutter.sdk` in android/local.properties " +
                "or define FLUTTER_ROOT environment variable."
    )

includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
// 1) 插件仓库
pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

// 4) 统一依赖仓库（避免子模块声明 repositories）
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io") // libsu 用
        val storageUrl = System.getenv("FLUTTER_STORAGE_BASE_URL") ?: "https://storage.flutter-io.com"
        maven { url = uri("$storageUrl/download.flutter.io") }


    }
}

rootProject.name = "pppoe_controller"
include(":app")
