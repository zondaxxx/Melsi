package app.melsi.vpn

import android.annotation.SuppressLint
import android.app.Notification as AndroidNotification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.net.Uri
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.Settings
import android.system.OsConstants
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.melsi.MainActivity
import app.melsi.R
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.lang.ref.WeakReference
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

/**
 * The VPN: a foreground [VpnService] hosting sing-box (libbox [CommandServer]) and the melsi
 * engine. Implements libbox [PlatformInterface] (TUN, socket protection, default-interface
 * monitoring, connection owner lookup, local DNS …) the way sing-box-for-android 1.14 does.
 *
 * Start: [MelsiVpnService.start] (config must already be saved with [VpnProfileStore]).
 * Stop:  [MelsiVpnService.stop].
 * A start with a null intent (process restart via START_STICKY) or from Always-on VPN reuses
 * the last saved profile.
 */
class MelsiVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        private const val TAG = "MelsiVpnService"
        const val ACTION_START = "app.melsi.action.START"
        const val ACTION_STOP = "app.melsi.action.STOP"

        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_SERVICE = "melsi_vpn"

        private var instance: WeakReference<MelsiVpnService>? = null

        fun start(context: Context) {
            val intent = Intent(context, MelsiVpnService::class.java).setAction(ACTION_START)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val running = instance?.get()
            if (running != null) {
                running.requestStop()
                return
            }
            if (VpnState.status != VpnStatus.Stopped) VpnState.set(VpnStatus.Stopped)
        }

        private val pendingIntentFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private val serial = Dispatchers.IO.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + serial)

    private var commandServer: CommandServer? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private var profileName: String = ""
    private var systemProxyAvailable = false
    private var systemProxyEnabled = true

    private val connectivity by lazy { getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager }
    private val notificationManager by lazy { getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager }

    // region Service lifecycle

    override fun onCreate() {
        super.onCreate()
        instance = WeakReference(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            requestStop()
            return START_NOT_STICKY
        }
        // Must enter the foreground quickly after startForegroundService().
        showNotification(getString(R.string.vpn_status_connecting))
        val restart = intent?.action == ACTION_START
        scope.launch { startOrReload(restart) }
        return START_STICKY
    }

    override fun onRevoke() {
        // Another VPN took over or the user revoked consent.
        requestStop()
    }

    override fun onDestroy() {
        if (commandServer != null) {
            runBlocking(serial) { shutdown(null) }
        }
        if (instance?.get() === this) instance = null
        super.onDestroy()
    }

    fun requestStop(message: String? = null) {
        scope.launch { shutdown(message) }
    }

    private fun startOrReload(restartIfRunning: Boolean) {
        val running = commandServer != null && VpnState.status == VpnStatus.Connected
        if (running && !restartIfRunning) return
        VpnState.set(VpnStatus.Connecting)
        try {
            val profile = VpnProfileStore.load(this) ?: throw IllegalStateException("Нет сохранённой конфигурации")
            profileName = profile.name
            if (prepare(this) != null) throw IllegalStateException("Нет разрешения на VPN")
            LibboxRuntime.ensureSetup(this)
            DefaultNetworkMonitor.start(this)
            val server = commandServer ?: CommandServer(this, this).also {
                it.start()
                commandServer = it
            }
            if (running) MelsiEngine.stop()
            server.startOrReloadService(profile.config, OverrideOptions())
            var message: String? = null
            try {
                MelsiEngine.start(profile.engine)
            } catch (e: Exception) {
                Log.e(TAG, "start engine", e)
                message = "engine: ${e.message}"
            }
            VpnState.set(VpnStatus.Connected, message)
            showNotification(getString(R.string.vpn_status_connected))
        } catch (e: Exception) {
            Log.e(TAG, "start service", e)
            shutdown(e.message ?: e.toString())
        }
    }

    /** Runs on [serial]. Safe to call repeatedly. */
    private fun shutdown(message: String?) {
        if (commandServer == null && fileDescriptor == null && VpnState.status == VpnStatus.Stopped) {
            stopSelfCompat()
            return
        }
        VpnState.set(VpnStatus.Stopping)
        MelsiEngine.stop()
        commandServer?.let { server ->
            runCatching { server.closeService() }.onFailure { Log.w(TAG, "close service", it) }
            runCatching { server.close() }.onFailure { Log.w(TAG, "close command server", it) }
        }
        commandServer = null
        closeTun()
        DefaultNetworkMonitor.setListener(null)
        DefaultNetworkMonitor.stop()
        stopSelfCompat()
        VpnState.set(VpnStatus.Stopped, message)
    }

    private fun stopSelfCompat() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun closeTun() {
        fileDescriptor?.let { runCatching { it.close() } }
        fileDescriptor = null
    }

    // endregion

    // region Notification

    private fun ensureChannel(id: String, name: CharSequence, importance: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notificationManager.createNotificationChannel(NotificationChannel(id, name, importance))
        }
    }

    private fun showNotification(text: String) {
        ensureChannel(CHANNEL_SERVICE, getString(R.string.vpn_channel_name), NotificationManager.IMPORTANCE_LOW)
        val openApp = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            pendingIntentFlags,
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, MelsiVpnService::class.java).setAction(ACTION_STOP),
            pendingIntentFlags,
        )
        val notification: AndroidNotification = NotificationCompat.Builder(this, CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_melsi)
            .setContentTitle(profileName.ifBlank { getString(R.string.app_name) })
            .setContentText(text)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openApp)
            .addAction(0, getString(R.string.vpn_action_disconnect), stopIntent)
            .build()
        try {
            startForeground(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "startForeground", e)
        }
    }

    // endregion

    // region CommandServerHandler

    override fun serviceStop() {
        requestStop()
    }

    override fun serviceReload() {
        scope.launch { startOrReload(true) }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().also {
        it.available = systemProxyAvailable
        it.enabled = systemProxyEnabled
    }

    override fun setSystemProxyEnabled(enabled: Boolean) {
        systemProxyEnabled = enabled
        serviceReload()
    }

    override fun triggerNativeCrash() {
        throw UnsupportedOperationException("not supported")
    }

    override fun writeDebugMessage(message: String?) {
        Log.d("sing-box", message.orEmpty())
    }

    override fun connectSSHAgent(): Int = -1

    // endregion

    // region PlatformInterface

    override fun localDNSTransport(): LocalDNSTransport = LocalResolver

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder()
            .setSession(profileName.ifBlank { "Melsi" })
            .setMtu(options.mtu)
            .setConfigureIntent(
                PendingIntent.getActivity(
                    this, 0, Intent(this, MainActivity::class.java), pendingIntentFlags,
                ),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        val inet4Address = options.inet4Address.toList()
        val inet6Address = options.inet6Address.toList()
        inet4Address.forEach { builder.addAddress(it.address(), it.prefix()) }
        inet6Address.forEach { builder.addAddress(it.address(), it.prefix()) }

        if (options.autoRoute) {
            if (options.dnsMode.value != Libbox.DNSModeDisabled) {
                options.dnsServerAddress.toList().forEach { builder.addDnsServer(it) }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4Routes = options.inet4RouteAddress.toList()
                if (inet4Routes.isNotEmpty()) {
                    inet4Routes.forEach { builder.addRoute(it.toIpPrefix()) }
                } else if (inet4Address.isNotEmpty()) {
                    builder.addRoute("0.0.0.0", 0)
                }
                val inet6Routes = options.inet6RouteAddress.toList()
                if (inet6Routes.isNotEmpty()) {
                    inet6Routes.forEach { builder.addRoute(it.toIpPrefix()) }
                } else if (inet6Address.isNotEmpty()) {
                    builder.addRoute("::", 0)
                }
                options.inet4RouteExcludeAddress.toList().forEach { builder.excludeRoute(it.toIpPrefix()) }
                options.inet6RouteExcludeAddress.toList().forEach { builder.excludeRoute(it.toIpPrefix()) }
            } else {
                // Pre-13: sing-box pre-computes route ranges with the excludes subtracted.
                options.inet4RouteRange.toList().forEach { builder.addRoute(it.address(), it.prefix()) }
                options.inet6RouteRange.toList().forEach { builder.addRoute(it.address(), it.prefix()) }
            }

            val include = options.includePackage.toList()
            val exclude = options.excludePackage.toList()
            if (include.isNotEmpty()) {
                // Same as SFA: our own package always goes through the tunnel in include mode.
                (include + packageName).distinct().forEach { pkg ->
                    try {
                        builder.addAllowedApplication(pkg)
                    } catch (e: PackageManager.NameNotFoundException) {
                        Log.w(TAG, "addAllowedApplication $pkg: not installed")
                    }
                }
            } else if (exclude.isNotEmpty()) {
                exclude.filter { it != packageName }.distinct().forEach { pkg ->
                    try {
                        builder.addDisallowedApplication(pkg)
                    } catch (e: PackageManager.NameNotFoundException) {
                        Log.w(TAG, "addDisallowedApplication $pkg: not installed")
                    }
                }
            }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            if (systemProxyEnabled) {
                builder.setHttpProxy(
                    ProxyInfo.buildDirectProxy(
                        options.httpProxyServer,
                        options.httpProxyServerPort,
                        options.httpProxyBypassDomain.toList(),
                    ),
                )
            }
        } else {
            systemProxyAvailable = false
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        // libbox dup()s the fd; the previous one (config reload) is ours to close.
        val previous = fileDescriptor
        fileDescriptor = pfd
        previous?.let { runCatching { it.close() } }
        return pfd.fd
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    @SuppressLint("NewApi")
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) error("android: not supported below Q")
        val uid = connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        val packages = packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return ConnectionOwner().also {
            it.userId = uid
            it.userName = packages.firstOrNull() ?: ""
            it.setAndroidPackageNames(StringArray(packages))
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(null)
    }

    @Suppress("DEPRECATION")
    override fun getInterfaces(): NetworkInterfaceIterator {
        val networkInterfaces = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        val interfaces = mutableListOf<LibboxNetworkInterface>()
        for (network in connectivity.allNetworks) {
            val linkProperties = connectivity.getLinkProperties(network) ?: continue
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            val name = linkProperties.interfaceName ?: continue
            val networkInterface = networkInterfaces.find { it.name == name } ?: continue
            val boxInterface = LibboxNetworkInterface()
            boxInterface.name = name
            boxInterface.index = networkInterface.index
            runCatching { boxInterface.mtu = networkInterface.mtu }
            boxInterface.dnsServer = StringArray(linkProperties.dnsServers.mapNotNull { it.hostAddress })
            boxInterface.gateway = StringArray(
                linkProperties.routes
                    .filter { it.destination.prefixLength == 0 }
                    .mapNotNull { it.gateway }
                    .filterNot { it.isAnyLocalAddress }
                    .mapNotNull { it.hostAddress },
            )
            boxInterface.type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                else -> Libbox.InterfaceTypeOther
            }
            boxInterface.addresses = StringArray(networkInterface.interfaceAddresses.map { it.toPrefix() })
            var flags = 0
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                flags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            }
            if (networkInterface.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
            if (networkInterface.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
            if (networkInterface.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            boxInterface.flags = flags
            boxInterface.metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            interfaces.add(boxInterface)
        }
        return InterfaceArray(interfaces.iterator())
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    @Suppress("DEPRECATION")
    override fun readWIFIState(): WIFIState? {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        val info = runCatching { wifiManager.connectionInfo }.getOrNull() ?: return null
        var ssid = info.ssid ?: return null
        if (ssid == "<unknown ssid>") return WIFIState("", "")
        if (ssid.startsWith("\"") && ssid.endsWith("\"")) ssid = ssid.substring(1, ssid.length - 1)
        return WIFIState(ssid, info.bssid ?: "")
    }

    override fun clearDNSCache() {}

    override fun sendNotification(notification: Notification) {
        val channel = "notification-${notification.typeID}"
        ensureChannel(channel, notification.typeName ?: "sing-box", NotificationManager.IMPORTANCE_HIGH)
        val builder = NotificationCompat.Builder(this, channel)
            .setSmallIcon(R.drawable.ic_stat_melsi)
            .setShowWhen(false)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
        if (!notification.subtitle.isNullOrBlank()) builder.setSubText(notification.subtitle)
        val openUrl = notification.openURL
        val contentIntent = if (!openUrl.isNullOrBlank()) {
            Intent(Intent.ACTION_VIEW, Uri.parse(openUrl))
        } else {
            Intent(this, MainActivity::class.java)
        }
        builder.setContentIntent(PendingIntent.getActivity(this, 2, contentIntent, pendingIntentFlags))
        try {
            notificationManager.notify(notification.identifier, notification.typeID, builder.build())
        } catch (e: SecurityException) {
            Log.w(TAG, "notify: ${e.message}")
        }
    }

    override fun cancelNotification(identifier: String, typeID: Int) {
        notificationManager.cancel(identifier, typeID)
    }

    // Neighbor table needs root on Android; not supported.
    override fun startNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun registerMyInterface(name: String?) {}

    override fun usePlatformShell(): Boolean = false

    override fun checkPlatformShell() {
        error("not supported")
    }

    override fun openShellSession(
        user: PlatformUser?,
        command: String?,
        environ: StringIterator?,
        term: String?,
        rows: Int,
        cols: Int,
    ): ShellSession = error("not supported")

    override fun lookupUser(username: String?): PlatformUser = error("not supported")

    override fun lookupSFTPServer(): String = error("not supported")

    override fun readSystemSSHHostKey(): String = error("not supported")

    override fun tailscaleHostname(): String =
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"

    override fun usePlatformBridge(): Boolean = false

    override fun createBridge(options: BridgeOptions?): BridgeSession = error("not supported")

    // endregion

    private fun InterfaceAddress.toPrefix(): String = if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
    } else {
        "${address.hostAddress}/$networkPrefixLength"
    }
}
