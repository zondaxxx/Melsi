package app.melsi.vpn

/** Process-wide intent ordering, including starts not yet delivered to the service. */
internal class VpnServiceRequests {
    private var generation = 0L
    private var startRequested = false

    @Synchronized
    fun start(): Long {
        startRequested = true
        return ++generation
    }

    @Synchronized
    fun stop(): Long {
        startRequested = false
        return ++generation
    }

    @Synchronized
    fun stopIfCurrent(request: Long): Long? = if (request == generation) stop() else null

    @Synchronized
    fun isCurrent(request: Long): Boolean = request == generation

    @Synchronized
    fun mayStart(request: Long): Boolean = request == generation && startRequested

    @Synchronized
    fun wantsStart(): Boolean = startRequested

    /** Only short platform teardown calls belong here, never native shutdown. */
    @Synchronized
    fun ifStopped(action: () -> Unit) {
        if (!startRequested) action()
    }
}
