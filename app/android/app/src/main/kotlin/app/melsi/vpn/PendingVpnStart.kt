package app.melsi.vpn

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Main-thread coordinator for the asynchronous profile write before a VPN start. */
internal class PendingVpnStart {
    private var generation = 0L
    private val writes = Mutex()

    fun invalidate() {
        generation++
    }

    suspend fun start(persist: suspend () -> Unit, connect: () -> Unit) {
        val requested = ++generation
        // Never let an older disk write overwrite the profile of a newer start.
        writes.withLock {
            ensureCurrent(requested)
            persist()
            // Stop can arrive while persist is suspended on the IO dispatcher.
            ensureCurrent(requested)
            connect()
        }
    }

    private fun ensureCurrent(requested: Long) {
        if (requested != generation) throw CancellationException("VPN start was superseded")
    }
}
