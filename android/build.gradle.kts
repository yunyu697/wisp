allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 有些插件子项目自带的 compileSdk 低于其依赖要求的 API 级别
// （file_picker 8.3.7 编译于 android-34，而 flutter_plugin_android_lifecycle 要求 36），
// AAR 元数据检查会在这些子项目上报错。反射统一抬到 36，
// 不直接引用 AGP 类（AGP 9 移除了旧 BaseExtension，类型引用容易踩版本坑）。
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        val current = android.javaClass.methods
            .firstOrNull { it.name == "getCompileSdk" && it.parameterCount == 0 }
            ?.invoke(android) as? Int ?: return@afterEvaluate
        if (current < 36) {
            android.javaClass.methods
                .firstOrNull {
                    it.name == "setCompileSdk" && it.parameterCount == 1 &&
                        (it.parameterTypes[0] == Integer.TYPE || it.parameterTypes[0] == Integer::class.java)
                }
                ?.invoke(android, 36)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
