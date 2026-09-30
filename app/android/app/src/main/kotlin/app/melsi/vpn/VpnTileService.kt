package app.melsi.vpn

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import app.melsi.MainActivity
import app.melsi.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Quick Settings tile: one tap connects / disconnects using the last saved profile. */
class VpnTileService : TileService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var job: Job? = null

    override fun onStartListening() {
        super.onStartListening()
        job?.cancel()
        job = scope.launch { VpnState.state.collect { render(it.status) } }
    }

    override fun onStopListening() {
        job?.cancel()
        job = null
        super.onStopListening()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onClick() {
        if (isLocked) {
            unlockAndRun { toggle() }
        } else {
            toggle()
        }
    }

    private fun toggle() {
        when (VpnState.status) {
            VpnStatus.Connected, VpnStatus.Connecting -> MelsiVpnService.stop(this)
            VpnStatus.Stopping -> Unit
            VpnStatus.Stopped -> {
                if (!VpnProfileStore.hasProfile(this) || VpnService.prepare(this) != null) {
                    openApp()
                } else {
                    MelsiVpnService.start(this)
                }
            }
        }
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun render(status: VpnStatus) {
        val tile = qsTile ?: return
        tile.state = when (status) {
            VpnStatus.Connected -> Tile.STATE_ACTIVE
            VpnStatus.Stopped -> Tile.STATE_INACTIVE
            else -> Tile.STATE_UNAVAILABLE
        }
        tile.label = getString(R.string.app_name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when (status) {
                VpnStatus.Connected -> getString(R.string.vpn_tile_on)
                VpnStatus.Connecting -> getString(R.string.vpn_status_connecting)
                VpnStatus.Stopping -> getString(R.string.vpn_status_stopping)
                VpnStatus.Stopped -> getString(R.string.vpn_tile_off)
            }
        }
        tile.updateTile()
    }
}
