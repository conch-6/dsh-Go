// Self-ADB (wireless debugging) path to a shell-uid process, the Shizuku-free way; ADB protocol,
// TLS pairing and mDNS come from libadb-android. This side adds discovery, key storage, the
// pairing flow and the app_process launch.
package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.content.Context
import android.net.InetAddresses
import android.os.Build
import android.provider.Settings
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.android.AdbMdns
import java.io.File
import java.net.InetAddress
import java.security.PrivateKey
import java.security.cert.Certificate
import java.util.concurrent.TimeUnit

/** wirelessDebugging / paired / connected for the status Map. */
data class AdbStatus(
    val wirelessDebugging: Boolean?,
    val paired: Boolean,
    val connected: Boolean,
) {
    fun map(): Map<String, Any?> =
        mapOf("wirelessDebugging" to wirelessDebugging, "paired" to paired, "connected" to connected)
}

class AdbStarter(private val context: Context, private val onChanged: () -> Unit) {

    private val keys = AdbKeyStore(context)
    private val pairedFlag = File(File(context.filesDir, "phone-adb"), "paired").apply { parentFile?.mkdirs() }

    private val manager = object : AbsAdbConnectionManager() {
        init {
            setApi(Build.VERSION.SDK_INT)
            setTimeout(8, TimeUnit.SECONDS)
        }
        override fun getPrivateKey(): PrivateKey = keys.privateKey()
        override fun getCertificate(): Certificate = keys.certificate()
        override fun getDeviceName(): String = "dsh-app"
    }

    @Volatile private var pairingMdns: AdbMdns? = null
    @Volatile private var connectMdns: AdbMdns? = null
    @Volatile private var pairEndpoint: AdbEndpoint? = null
    @Volatile private var connectEndpoint: AdbEndpoint? = null
    @Volatile private var channel: AdbChannel? = null

    fun status(): AdbStatus = AdbStatus(wirelessDebugging(), pairedFlag.exists(), channel?.alive() == true)

    fun reason(): String? = when {
        channel?.alive() == true -> null
        !pairedFlag.exists() -> AppStrings.get(context, R.string.background_adb_not_paired)
        else -> AppStrings.get(context, R.string.background_adb_disconnected)
    }

    private fun wirelessDebugging(): Boolean? = runCatching {
        // Reported as unknown from API 36 (Android 16) on. AOSP 17 redacts `adb_enabled` to 0 for
        // third-party apps; `adb_wifi_enabled` is still readable there, so this cutoff is conservative.
        if (Build.VERSION.SDK_INT >= 36) return@runCatching null
        Settings.Global.getInt(context.contentResolver, "adb_wifi_enabled", 0) == 1
    }.getOrDefault(null)

    /** Begins mDNS discovery of the pairing service so [pair] can target the live port. */
    fun startPairing(): Map<String, Any?> {
        stopMdns()
        pairEndpoint = null
        connectEndpoint = null
        pairingMdns = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_PAIRING) { address, port ->
            AdbEndpoint.discovered(address, port)?.let { pairEndpoint = it; onChanged() }
        }.also { it.start() }
        connectMdns = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_CONNECT) { address, port ->
            AdbEndpoint.discovered(address, port)?.let { connectEndpoint = it; onChanged() }
        }.also { it.start() }
        return mapOf("ok" to true)
    }

    /** Pairs with the 6-digit code. [port] overrides mDNS (for the App's manual fallback dialog). */
    fun pair(code: String, port: Int?): Map<String, Any?> {
        if (!code.matches(Regex("\\d{6}"))) return fail(AppStrings.get(context, R.string.pairing_invalid_code))
        val discovered = pairEndpoint
        val host = if (port != null) loopback() else discovered?.address ?: loopback()
        val target = port ?: discovered?.port ?: return fail(AppStrings.get(context, R.string.pairing_port_missing))
        if (target !in 1..65535) return fail(AppStrings.get(context, R.string.background_adb_invalid_port))
        return try {
            val ok = manager.pair(host.hostAddress ?: "127.0.0.1", target, code)
            if (ok) { pairedFlag.writeText("ok"); onChanged() }
            mapOf("ok" to ok, "reason" to if (ok) null else AppStrings.get(context, R.string.pairing_failed))
        } catch (e: Exception) {
            fail(AppStrings.get(context, R.string.pairing_error, e.javaClass.simpleName))
        } finally {
            runCatching { pairingMdns?.stop() }; pairingMdns = null
            pairEndpoint = null
        }
    }

    /** Connects to the local adbd and launches the privileged app_process. */
    fun connect(port: Int? = null): PrivilegedChannel? {
        if (port != null && port !in 1..65535) return null
        channel?.takeIf { it.alive() }?.let { return it }
        if (!pairedFlag.exists()) return null
        channel?.let { runCatching { it.close() } }
        channel = null
        runCatching { manager.disconnect() }
        return try {
            val discovered = connectEndpoint
            val connected = if (port != null) {
                // The connect port on Wireless debugging's main page is different
                // from its short-lived pairing port. Manual input targets this device.
                manager.connect("127.0.0.1", port)
            } else if (discovered != null) {
                val cached = runCatching {
                    manager.connect(discovered.address.hostAddress ?: "127.0.0.1", discovered.port)
                }.getOrDefault(false)
                if (cached) true else {
                    // Toggling wireless debugging or changing networks rotates the port.
                    connectEndpoint = null
                    runCatching { manager.disconnect() }
                    manager.autoConnect(context, TimeUnit.SECONDS.toMillis(8))
                }
            } else {
                manager.autoConnect(context, TimeUnit.SECONDS.toMillis(8))
            }
            if (!connected && !manager.isConnected) return null
            val stream = manager.openStream("shell:" + appProcessCommand())
            val value = AdbChannel(stream)
            val probe = value.execute(android.os.Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
            if (probe.getBoolean(Proto.OK) && probe.getString("revision") == Proto.REVISION) {
                channel = value; onChanged(); value
            } else { value.close(); null }
        } catch (_: Exception) {
            connectEndpoint = null
            runCatching { manager.disconnect() }
            null
        } finally {
            onChanged()
        }
    }

    fun disconnect() {
        channel?.let { runCatching { it.close() } }
        channel = null
        runCatching { manager.disconnect() }
        stopMdns()
        pairEndpoint = null
        connectEndpoint = null
        onChanged()
    }

    private fun appProcessCommand(): String {
        val info = context.applicationInfo
        val classpath = buildList {
            add(info.sourceDir)
            info.splitSourceDirs?.let { addAll(it.toList()) }
        }.joinToString(":")
        val main = PrivilegedDisplayMain::class.java.name
        return "CLASSPATH=$classpath app_process /system/bin $main"
    }

    private fun stopMdns() {
        runCatching { pairingMdns?.stop() }; pairingMdns = null
        runCatching { connectMdns?.stop() }; connectMdns = null
    }

    private fun loopback(): InetAddress = InetAddresses.parseNumericAddress("127.0.0.1")
    private fun fail(reason: String): Map<String, Any?> = mapOf("ok" to false, "reason" to reason)
}
