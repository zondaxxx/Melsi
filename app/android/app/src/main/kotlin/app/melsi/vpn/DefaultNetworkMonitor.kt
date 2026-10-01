package app.melsi.vpn

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.nekohasekai.libbox.InterfaceUpdateListener
import java.net.NetworkInterface

/**
 * Tracks the underlying (non-VPN) default network and reports it to sing-box so that
 * outbound sockets are bound to the right interface. Ported from sing-box-for-android
 * (DefaultNetworkMonitor + DefaultNetworkListener), without the coroutine actor.
 */
object DefaultNetworkMonitor {
    private const val TAG = "MelsiNetMonitor"

    @Volatile
    var defaultNetwork: Network? = null
        private set

    @Volatile
    private var listener: InterfaceUpdateListener? = null
    private var connectivity: ConnectivityManager? = null
    private var registered = false

    private val handler by lazy {
        Handler(HandlerThread("melsi-network-callback").apply { start() }.looper)
    }

    private val request: NetworkRequest =
        NetworkRequest.Builder().apply {
            addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        }.build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            defaultNetwork = network
            notifyListener(network)
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            if (network == defaultNetwork) notifyListener(network)
        }

        override fun onLost(network: Network) {
            if (network == defaultNetwork) {
                defaultNetwork = null
                notifyListener(null)
            }
        }
    }

    @Synchronized
    fun start(context: Context) {
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivity = cm
        if (!registered) {
            try {
                when {
                    Build.VERSION.SDK_INT >= 31 -> cm.registerBestMatchingNetworkCallback(request, callback, handler)
                    // REQUEST (not LISTEN): registerDefaultNetworkCallback returns the VPN itself on P+.
                    Build.VERSION.SDK_INT >= 28 -> cm.requestNetwork(request, callback, handler)
                    Build.VERSION.SDK_INT >= 26 -> cm.registerDefaultNetworkCallback(callback, handler)
                    else -> cm.registerDefaultNetworkCallback(callback)
                }
                registered = true
            } catch (e: Exception) {
                Log.e(TAG, "register network callback", e)
            }
        }
        if (defaultNetwork == null) defaultNetwork = cm.activeNetwork
    }

    @Synchronized
    fun stop() {
        if (registered) {
            runCatching { connectivity?.unregisterNetworkCallback(callback) }
            registered = false
        }
        defaultNetwork = null
    }

    fun setListener(listener: InterfaceUpdateListener?) {
        this.listener = listener
        if (listener != null) notifyListener(defaultNetwork)
    }

    @SuppressLint("NewApi")
    private fun notifyListener(network: Network?) {
        val listener = listener ?: return
        val cm = connectivity ?: return
        if (network == null) {
            listener.updateDefaultInterface("", -1, false, false)
            return
        }
        repeat(10) {
            val linkProperties = cm.getLinkProperties(network)
            val name = linkProperties?.interfaceName
            if (name != null) {
                val index = runCatching { NetworkInterface.getByName(name)?.index }.getOrNull()
                if (index != null) {
                    val caps = cm.getNetworkCapabilities(network)
                    val expensive = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
                    listener.updateDefaultInterface(name, index, expensive, false)
                    return
                }
            }
            Thread.sleep(100)
        }
    }
}
