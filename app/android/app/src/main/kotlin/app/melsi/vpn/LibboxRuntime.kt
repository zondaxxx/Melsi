package app.melsi.vpn

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.util.Log
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File
import java.util.Locale

/** One-time libbox initialisation for this process. */
object LibboxRuntime {
    private const val TAG = "MelsiLibbox"

    @Volatile
    private var initialized = false

    fun baseDir(context: Context): File = context.filesDir

    fun workingDir(context: Context): File = File(context.filesDir, "sing-box")

    fun tempDir(context: Context): File = context.cacheDir

    @Synchronized
    fun ensureSetup(context: Context) {
        if (initialized) return
        val app = context.applicationContext
        val baseDir = baseDir(app).apply { mkdirs() }
        val workingDir = workingDir(app).apply { mkdirs() }
        val tempDir = tempDir(app).apply { mkdirs() }
        runCatching { Libbox.setLocale(Locale.getDefault().toLanguageTag()) }
        val debuggable = (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val options = SetupOptions().also {
            it.basePath = baseDir.path
            it.workingPath = workingDir.path
            it.tempPath = tempDir.path
            // https://github.com/golang/go/issues/68760 (same condition as sing-box-for-android)
            it.fixAndroidStack = debuggable ||
                Build.VERSION.SDK_INT in Build.VERSION_CODES.N..Build.VERSION_CODES.N_MR1 ||
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
            it.logMaxLines = 3000
            it.debug = debuggable
            it.crashReportSource = "Application"
            it.appVersion = appVersionCode(app).toString()
            it.appMarketingVersion = appVersionName(app)
            it.oomKillerEnabled = false
            it.oomKillerDisabled = false
            it.oomMemoryLimit = 0
            it.powerReportEnabled = false
        }
        Libbox.setup(options)
        initialized = true
        Log.i(TAG, "libbox ${Libbox.version()} initialised")
    }

    fun version(): String = runCatching { Libbox.version() }.getOrElse { "unknown" }

    @Suppress("DEPRECATION")
    private fun appVersionCode(context: Context): Long = runCatching {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
    }.getOrDefault(0L)

    private fun appVersionName(context: Context): String = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull() ?: ""
}

/**
 * Bridge to the Go `melsicore` package (`io.nekohasekai.melsicore.Melsicore`), bound into the
 * same libbox.aar. Called reflectively so the app still works with an aar that only contains
 * libbox (engine features are simply unavailable then).
 */
object MelsiEngine {
    private const val TAG = "MelsiEngine"
    private const val CLASS_NAME = "io.nekohasekai.melsicore.Melsicore"

    private val clazz: Class<*>? by lazy {
        try {
            Class.forName(CLASS_NAME)
        } catch (e: Throwable) {
            Log.w(TAG, "melsicore not bundled in libbox.aar: ${e.message}")
            null
        }
    }

    val available: Boolean get() = clazz != null

    /** Throws the Go error (unwrapped) if the engine fails to start. */
    fun start(engineJson: String) {
        if (engineJson.isBlank()) return
        val c = clazz ?: return
        try {
            c.getMethod("startEngine", String::class.java).invoke(null, engineJson)
        } catch (e: java.lang.reflect.InvocationTargetException) {
            throw (e.targetException as? Exception) ?: RuntimeException(e.targetException)
        }
    }

    fun stop() {
        val c = clazz ?: return
        try {
            c.getMethod("stopEngine").invoke(null)
        } catch (e: Throwable) {
            Log.w(TAG, "stopEngine failed", e)
        }
    }

    fun version(): String? {
        val c = clazz ?: return null
        return runCatching { c.getMethod("version").invoke(null) as? String }.getOrNull()
    }
}
