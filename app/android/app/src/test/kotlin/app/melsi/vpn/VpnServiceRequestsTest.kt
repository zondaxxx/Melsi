package app.melsi.vpn

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class VpnServiceRequestsTest {
    @Test(timeout = 10_000)
    fun stopAfterProfileSavedStillRejectsUndeliveredServiceIntent() = runBlocking {
        val pending = PendingVpnStart()
        val requests = VpnServiceRequests()
        val queuedIntents = mutableListOf<Long>()
        val request = requests.start()
        pending.start(persist = {}, connect = { if (requests.mayStart(request)) queuedIntents.add(request) })

        // startForegroundService returned, but onCreate has not run yet.
        pending.invalidate()
        requests.stop()
        val accepted = queuedIntents.filter { requests.mayStart(it) }
        assertTrue(accepted.isEmpty())
        assertFalse(requests.wantsStart())
    }

    @Test(timeout = 10_000)
    fun notificationStopWhileSavingInvalidatesTheReservedStart() = runBlocking {
        val pending = PendingVpnStart()
        val requests = VpnServiceRequests()
        val saved = CompletableDeferred<Unit>()
        var serviceQueued = false
        val request = requests.start()
        val saving = async(start = CoroutineStart.UNDISPATCHED) {
            pending.start(persist = { saved.await() }, connect = {
                if (requests.mayStart(request)) serviceQueued = true
            })
        }
        // Notification and revoke have no reference to the Flutter activity.
        requests.stop()
        saved.complete(Unit)
        saving.await()
        assertFalse(serviceQueued)
        assertFalse(requests.wantsStart())
    }

    @Test(timeout = 10_000)
    fun delayedOldIntentCannotReplaceTheNewestRequestedSession() {
        val requests = VpnServiceRequests()
        val old = requests.start()
        requests.stop()
        val latest = requests.start()

        // Delivery order does not give a stale intent permission to run.
        assertEquals(listOf(latest), listOf(old, latest).filter { requests.mayStart(it) })
        assertEquals(listOf(latest), listOf(latest, old).filter { requests.mayStart(it) })
        assertTrue(requests.wantsStart())
    }

    @Test(timeout = 10_000)
    fun stopDuringNativeStartupRejectsCompletionAndLateReload() {
        val requests = VpnServiceRequests()
        val acceptedSession = requests.start()
        assertTrue(requests.mayStart(acceptedSession))
        val stop = requests.stop()

        assertFalse(requests.mayStart(acceptedSession))
        assertTrue(requests.isCurrent(stop))
        // A reload reuses the accepted session token, never creates a start.
        assertFalse(requests.mayStart(acceptedSession))
    }

    @Test(timeout = 10_000)
    fun supersededStartupFailureCannotStopTheReplacement() {
        val requests = VpnServiceRequests()
        val old = requests.start()
        val latest = requests.start()

        assertNull(requests.stopIfCurrent(old))
        assertTrue(requests.mayStart(latest))
        assertNotNull(requests.stopIfCurrent(latest))
        assertFalse(requests.mayStart(latest))
    }

    @Test(timeout = 10_000)
    fun newStartWhileShutdownRunsKeepsServiceForItsIntent() {
        val requests = VpnServiceRequests()
        requests.start()
        val stop = requests.stop()
        assertTrue(requests.isCurrent(stop))
        val restart = requests.start()

        assertFalse(requests.isCurrent(stop))
        assertTrue(requests.wantsStart())
        assertTrue(requests.mayStart(restart))
        var serviceStopped = false
        requests.ifStopped { serviceStopped = true }
        assertFalse(serviceStopped)
    }

    @Test(timeout = 10_000)
    fun platformStopFinishesBeforeAnotherThreadCanReserveStart() {
        val requests = VpnServiceRequests()
        requests.stop()
        val attemptingStart = CountDownLatch(1)
        val reservedStart = CountDownLatch(1)
        var startThread: Thread? = null
        requests.ifStopped {
            startThread = thread {
                attemptingStart.countDown()
                requests.start()
                reservedStart.countDown()
            }
            assertTrue(attemptingStart.await(1, TimeUnit.SECONDS))
            // Hold the platform-stop guard while the other thread requests a
            // start: it must not reserve a token that stopSelf could then kill.
            assertFalse(reservedStart.await(100, TimeUnit.MILLISECONDS))
        }
        assertTrue(reservedStart.await(1, TimeUnit.SECONDS))
        startThread?.join(1000)
        assertTrue(requests.wantsStart())
    }
}
