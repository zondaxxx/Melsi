package app.melsi.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log

/**
 * Connect on boot / after app update, when the user enabled it (flag file written via the
 * `setConnectOnBoot` method) and a profile + VPN consent exist.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> Unit
            else -> return
        }
        if (!VpnProfileStore.isConnectOnBoot(context)) return
        if (!VpnProfileStore.hasProfile(context)) return
        if (VpnService.prepare(context) != null) return
        if (VpnState.status != VpnStatus.Stopped) return
        try {
            MelsiVpnService.start(context)
        } catch (e: Exception) {
            Log.e("MelsiBoot", "start on boot", e)
        }
    }
}
