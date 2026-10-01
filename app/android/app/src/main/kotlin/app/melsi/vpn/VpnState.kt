package app.melsi.vpn

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Status strings are part of the Dart contract (docs/CONTRACT.md §5). */
enum class VpnStatus(val wire: String) {
    Stopped("stopped"),
    Connecting("connecting"),
    Connected("connected"),
    Stopping("stopping"),
}

data class VpnStateSnapshot(val status: VpnStatus, val message: String? = null) {
    fun toMap(): Map<String, Any?> = mapOf("state" to status.wire, "message" to message)
}

/**
 * Process-local state shared between [MelsiVpnService], the Flutter activity and the
 * Quick Settings tile. Everything runs in the main app process, so a StateFlow is enough.
 */
object VpnState {
    private val _state = MutableStateFlow(VpnStateSnapshot(VpnStatus.Stopped))
    val state: StateFlow<VpnStateSnapshot> = _state.asStateFlow()

    val status: VpnStatus get() = _state.value.status

    fun set(status: VpnStatus, message: String? = null) {
        _state.value = VpnStateSnapshot(status, message)
    }
}
