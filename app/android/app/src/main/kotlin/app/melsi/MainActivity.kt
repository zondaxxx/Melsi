package app.melsi

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.VpnService
import android.os.Build
import app.melsi.vpn.LibboxRuntime
import app.melsi.vpn.MelsiVpnService
import app.melsi.vpn.VpnProfileStore
import app.melsi.vpn.VpnState
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/**
 * Flutter host + mobile bridge (docs/CONTRACT.md §5):
 *   MethodChannel `app.melsi/vpn`, EventChannel `app.melsi/vpn/events`.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "app.melsi/vpn"
        private const val EVENT_CHANNEL = "app.melsi/vpn/events"
        private const val REQUEST_VPN = 0x4D31
        private const val REQUEST_NOTIFICATIONS = 0x4D32
        private const val ICON_SIZE = 96
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var pendingPrepare: MethodChannel.Result? = null
    private var eventsJob: Job? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(::onMethodCall)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                eventsJob?.cancel()
                eventsJob = scope.launch {
                    VpnState.state.collect { events.success(it.toMap()) }
                }
            }

            override fun onCancel(arguments: Any?) {
                eventsJob?.cancel()
                eventsJob = null
            }
        })
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepare(result)
            "start" -> start(call, result)
            "stop" -> {
                MelsiVpnService.stop(this)
                result.success(null)
            }
            "status" -> result.success(VpnState.status.wire)
            "coreVersion" -> scope.launch {
                result.success(withContext(Dispatchers.IO) { LibboxRuntime.version() })
            }
            "installedApps" -> scope.launch {
                try {
                    result.success(withContext(Dispatchers.IO) { installedApps() })
                } catch (e: Exception) {
                    result.error("apps", e.message, null)
                }
            }
            "appIcon" -> {
                val pkg = call.argument<String>("package")
                if (pkg.isNullOrEmpty()) {
                    result.success(null)
                } else {
                    scope.launch { result.success(withContext(Dispatchers.IO) { appIcon(pkg) }) }
                }
            }
            // Android-only extras (not required by the contract).
            "setConnectOnBoot" -> {
                VpnProfileStore.setConnectOnBoot(this, call.argument<Boolean>("enabled") == true)
                result.success(null)
            }
            "getConnectOnBoot" -> result.success(VpnProfileStore.isConnectOnBoot(this))
            else -> result.notImplemented()
        }
    }

    // region prepare

    private fun prepare(result: MethodChannel.Result) {
        requestNotificationPermission()
        val intent = try {
            VpnService.prepare(this)
        } catch (e: Exception) {
            result.error("prepare", e.message, null)
            return
        }
        if (intent == null) {
            result.success(true)
            return
        }
        pendingPrepare?.success(false)
        pendingPrepare = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_VPN)
        } catch (e: Exception) {
            pendingPrepare = null
            result.error("prepare", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_VPN) {
            val granted = resultCode == RESULT_OK || VpnService.prepare(this) == null
            pendingPrepare?.success(granted)
            pendingPrepare = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
    }

    // endregion

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (config.isNullOrBlank()) {
            result.error("start", "config is empty", null)
            return
        }
        val engine = call.argument<String>("engine").orEmpty()
        val name = call.argument<String>("name").orEmpty()
        if (VpnService.prepare(this) != null) {
            result.error("start", "VPN permission not granted (call prepare first)", null)
            return
        }
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    VpnProfileStore.save(this@MainActivity, VpnProfileStore.Profile(config, engine, name))
                }
                MelsiVpnService.start(this@MainActivity)
                result.success(null)
            } catch (e: Exception) {
                result.error("start", e.message, null)
            }
        }
    }

    // region apps

    @Suppress("DEPRECATION")
    private fun installedApps(): List<Map<String, Any>> {
        val pm = packageManager
        val packages: List<PackageInfo> = try {
            pm.getInstalledPackages(PackageManager.GET_PERMISSIONS)
        } catch (e: Exception) {
            // Some devices throw TransactionTooLargeException with GET_PERMISSIONS.
            pm.getInstalledPackages(0)
        }
        return packages.asSequence()
            .filter { it.packageName != packageName }
            .filter { info ->
                val perms = info.requestedPermissions
                perms == null || perms.contains(Manifest.permission.INTERNET)
            }
            .mapNotNull { info ->
                val app = info.applicationInfo ?: return@mapNotNull null
                val label = runCatching { app.loadLabel(pm).toString() }.getOrDefault(info.packageName)
                mapOf(
                    "package" to info.packageName,
                    "label" to label,
                    "system" to ((app.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
            .toList()
    }

    private fun appIcon(pkg: String): ByteArray? = try {
        val drawable = packageManager.getApplicationIcon(pkg)
        val bitmap = drawable.toBitmap(ICON_SIZE)
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
    } catch (e: Exception) {
        null
    }

    private fun Drawable.toBitmap(maxSize: Int): Bitmap {
        if (this is BitmapDrawable && bitmap != null &&
            bitmap.width <= maxSize && bitmap.height <= maxSize
        ) {
            return bitmap
        }
        val w = intrinsicWidth.takeIf { it > 0 } ?: maxSize
        val h = intrinsicHeight.takeIf { it > 0 } ?: maxSize
        val scale = minOf(1f, maxSize.toFloat() / maxOf(w, h))
        val bw = maxOf(1, (w * scale).toInt())
        val bh = maxOf(1, (h * scale).toInt())
        val bmp = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val oldBounds = copyBounds()
        setBounds(0, 0, bw, bh)
        draw(canvas)
        bounds = oldBounds
        return bmp
    }

    // endregion
}
