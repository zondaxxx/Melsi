package app.melsi.vpn

import android.net.IpPrefix
import android.os.Build
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.StringIterator
import java.net.InetAddress
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

class StringArray(private val values: List<String>) : StringIterator {
    private var index = 0

    override fun len(): Int = values.size

    override fun hasNext(): Boolean = index < values.size

    override fun next(): String = values[index++]
}

class InterfaceArray(private val iterator: Iterator<LibboxNetworkInterface>) : NetworkInterfaceIterator {
    override fun hasNext(): Boolean = iterator.hasNext()

    override fun next(): LibboxNetworkInterface = iterator.next()
}

fun StringIterator?.toList(): List<String> {
    if (this == null) return emptyList()
    val out = mutableListOf<String>()
    while (hasNext()) out.add(next())
    return out
}

fun RoutePrefixIterator?.toList(): List<RoutePrefix> {
    if (this == null) return emptyList()
    val out = mutableListOf<RoutePrefix>()
    while (hasNext()) out.add(next())
    return out
}

@RequiresApi(Build.VERSION_CODES.TIRAMISU)
fun RoutePrefix.toIpPrefix(): IpPrefix = IpPrefix(InetAddress.getByName(address()), prefix())
