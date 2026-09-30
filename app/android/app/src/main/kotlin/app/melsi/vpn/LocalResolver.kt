package app.melsi.vpn

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * Resolves sing-box `local` DNS servers through the system resolver of the underlying
 * network (so it never loops through our own TUN). Port of SFA's LocalResolver; calls are
 * made from Go goroutines, so blocking here is fine.
 */
object LocalResolver : LocalDNSTransport {
    private const val RCODE_NXDOMAIN = 3
    private val executor = Executors.newCachedThreadPool()

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val network = DefaultNetworkMonitor.defaultNetwork ?: error("missing default interface")
        await(ctx) { signal, done ->
            DnsResolver.getInstance().rawQuery(
                network,
                message,
                DnsResolver.FLAG_NO_RETRY,
                executor,
                signal,
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        if (rcode == 0) ctx.rawSuccess(answer) else ctx.errorCode(rcode)
                        done(null)
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        val cause = error.cause
                        if (cause is ErrnoException) {
                            ctx.errnoCode(cause.errno)
                            done(null)
                        } else {
                            done(error)
                        }
                    }
                },
            )
        }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val defaultNetwork = DefaultNetworkMonitor.defaultNetwork ?: error("missing default interface")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            await(ctx) { signal, done ->
                val callback = object : DnsResolver.Callback<List<InetAddress>> {
                    override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                        if (rcode == 0) {
                            ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
                        } else {
                            ctx.errorCode(rcode)
                        }
                        done(null)
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        val cause = error.cause
                        if (cause is ErrnoException) {
                            ctx.errnoCode(cause.errno)
                            done(null)
                        } else {
                            done(error)
                        }
                    }
                }
                val type = when {
                    network.endsWith("4") -> DnsResolver.TYPE_A
                    network.endsWith("6") -> DnsResolver.TYPE_AAAA
                    else -> null
                }
                if (type != null) {
                    DnsResolver.getInstance().query(
                        defaultNetwork, domain, type, DnsResolver.FLAG_NO_RETRY, executor, signal, callback,
                    )
                } else {
                    DnsResolver.getInstance().query(
                        defaultNetwork, domain, DnsResolver.FLAG_NO_RETRY, executor, signal, callback,
                    )
                }
            }
        } else {
            val answer = try {
                defaultNetwork.getAllByName(domain)
            } catch (e: UnknownHostException) {
                ctx.errorCode(RCODE_NXDOMAIN)
                return
            }
            ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
        }
    }

    private inline fun await(
        ctx: ExchangeContext,
        start: (CancellationSignal, (Exception?) -> Unit) -> Unit,
    ) {
        val latch = CountDownLatch(1)
        val failure = AtomicReference<Exception?>(null)
        val signal = CancellationSignal()
        val done: (Exception?) -> Unit = { e ->
            if (latch.count > 0L) {
                failure.compareAndSet(null, e)
                latch.countDown()
            }
        }
        ctx.onCancel {
            signal.cancel()
            done(java.util.concurrent.CancellationException())
        }
        start(signal, done)
        latch.await()
        failure.get()?.let { throw it }
    }
}
