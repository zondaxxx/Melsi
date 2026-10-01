package app.melsi.vpn

import android.content.Context
import java.io.File

/**
 * Last started configuration, persisted so that Always-on VPN, the Quick Settings tile
 * and connect-on-boot can (re)start the tunnel without the Flutter UI.
 *
 * Layout (all inside the app's private files dir):
 *   files/melsi/config.json   sing-box config
 *   files/melsi/engine.json   melsi engine config
 *   files/melsi/name.txt      profile display name (notification title)
 *   files/melsi/connect_on_boot  flag file
 */
object VpnProfileStore {
    data class Profile(val config: String, val engine: String, val name: String)

    private fun dir(context: Context): File = File(context.filesDir, "melsi").apply { mkdirs() }

    fun save(context: Context, profile: Profile) {
        val dir = dir(context)
        writeAtomic(File(dir, "config.json"), profile.config)
        writeAtomic(File(dir, "engine.json"), profile.engine)
        writeAtomic(File(dir, "name.txt"), profile.name)
    }

    fun load(context: Context): Profile? {
        val dir = dir(context)
        val config = File(dir, "config.json").takeIf { it.isFile }?.readText() ?: return null
        if (config.isBlank()) return null
        val engine = File(dir, "engine.json").takeIf { it.isFile }?.readText().orEmpty()
        val name = File(dir, "name.txt").takeIf { it.isFile }?.readText().orEmpty()
        return Profile(config, engine, name)
    }

    fun hasProfile(context: Context): Boolean = File(dir(context), "config.json").isFile

    fun isConnectOnBoot(context: Context): Boolean = File(dir(context), "connect_on_boot").exists()

    fun setConnectOnBoot(context: Context, enabled: Boolean) {
        val file = File(dir(context), "connect_on_boot")
        if (enabled) file.writeText("1") else file.delete()
    }

    private fun writeAtomic(file: File, content: String) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(content)
        if (!tmp.renameTo(file)) {
            file.writeText(content)
            tmp.delete()
        }
    }
}
