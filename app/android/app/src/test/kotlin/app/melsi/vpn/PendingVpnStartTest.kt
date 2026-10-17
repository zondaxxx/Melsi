package app.melsi.vpn

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingVpnStartTest {
    @Test(timeout = 10_000)
    fun stopWhileSavingDoesNotLaunchVpn() = runBlocking {
        val starts = PendingVpnStart()
        val saved = CompletableDeferred<Unit>()
        var connected = false
        val pending = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching { starts.start(persist = { saved.await() }, connect = { connected = true }) }
        }

        starts.invalidate()
        saved.complete(Unit)

        assertTrue(pending.await().exceptionOrNull() is CancellationException)
        assertFalse(connected)
    }

    @Test(timeout = 10_000)
    fun newerStartWaitsForOlderWriteAndOnlyConnectsLatestProfile() = runBlocking {
        val starts = PendingVpnStart()
        val oldWrite = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        var persisted = ""
        val old = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching {
                starts.start(persist = {
                    events.add("old save started")
                    oldWrite.await()
                    persisted = "old"
                    events.add("old saved")
                }, connect = { events.add("connected $persisted") })
            }
        }
        val latest = async(start = CoroutineStart.UNDISPATCHED) {
            starts.start(persist = {
                persisted = "latest"
                events.add("latest saved")
            }, connect = { events.add("connected $persisted") })
        }
        assertEquals(listOf("old save started"), events)
        oldWrite.complete(Unit)

        assertTrue(old.await().exceptionOrNull() is CancellationException)
        latest.await()
        assertEquals(listOf("old save started", "old saved", "latest saved", "connected latest"), events)
        assertEquals("latest", persisted)
    }

    @Test(timeout = 10_000)
    fun stopAlsoCancelsStartWaitingForPreviousWrite() = runBlocking {
        val starts = PendingVpnStart()
        val oldWrite = CompletableDeferred<Unit>()
        var queuedWriteRan = false
        var connectCount = 0
        val first = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching { starts.start(persist = { oldWrite.await() }, connect = { connectCount++ }) }
        }
        val second = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching { starts.start(persist = { queuedWriteRan = true }, connect = { connectCount++ }) }
        }
        starts.invalidate()
        oldWrite.complete(Unit)

        assertTrue(first.await().exceptionOrNull() is CancellationException)
        assertTrue(second.await().exceptionOrNull() is CancellationException)
        assertFalse(queuedWriteRan)
        assertEquals(0, connectCount)
    }

    @Test(timeout = 10_000)
    fun failedSaveDoesNotLaunchAndReleasesNextStart() = runBlocking {
        val starts = PendingVpnStart()
        var connectCount = 0
        val failed = runCatching {
            starts.start(persist = { error("disk full") }, connect = { connectCount++ })
        }
        assertEquals("disk full", failed.exceptionOrNull()?.message)
        assertEquals(0, connectCount)

        starts.start(persist = {}, connect = { connectCount++ })
        assertEquals(1, connectCount)
    }
}
