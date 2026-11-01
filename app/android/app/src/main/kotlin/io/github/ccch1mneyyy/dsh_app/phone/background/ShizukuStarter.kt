// Portions derived from Phase (https://github.com/CikeSeven/phase), used with the author's permission. See THIRD_PARTY_NOTICES.md.
// Shizuku binding, permission and status, through the Shizuku API (dev.rikka.shizuku).
package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import rikka.shizuku.Shizuku

/** installed / running / granted plus a readiness verdict for the status Map. */
data class ShizukuStatus(
    val installed: Boolean,
    val running: Boolean,
    val granted: Boolean,
) {
    fun map(): Map<String, Any?> = mapOf("installed" to installed, "running" to running, "granted" to granted)
}

class ShizukuStarter(private val context: Context, private val onChanged: () -> Unit) {
    companion object {
        const val PACKAGE = "moe.shizuku.privileged.api"
        private const val PERMISSION_REQUEST_CODE = 4601

        /** 自动恢复无障碍's request, told apart from 不打扰模式's. */
        private const val GRANT_REQUEST_CODE = 4602
    }

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var channel: ShizukuChannel? = null
    @Volatile private var connection: ServiceConnection? = null
    @Volatile private var args: Shizuku.UserServiceArgs? = null
    @Volatile private var listenersAdded = false

    private val args0: Shizuku.UserServiceArgs
        get() = Shizuku.UserServiceArgs(ComponentName(context, PrivilegedDisplayService::class.java))
            .tag("dsh.vdisplay").processNameSuffix("vdisplay").version(1).daemon(false)

    fun installed(): Boolean =
        runCatching { context.packageManager.getApplicationInfo(PACKAGE, 0); true }.getOrDefault(false)

    fun running(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    fun granted(): Boolean = runCatching {
        running() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    fun status(): ShizukuStatus = ShizukuStatus(installed(), running(), granted())

    fun uid(): Int = runCatching { Shizuku.getUid() }.getOrDefault(-1)

    /** A one-line reason when not ready, else null. */
    fun reason(): String? {
        val status = status()
        return when {
            // Sui supplies the same Binder API without a Shizuku manager APK.
            // Installation is guidance only while no service is available.
            !status.running -> AppStrings.get(context, if (status.installed)
                R.string.background_shizuku_stopped else R.string.background_shizuku_missing)
            !status.granted -> AppStrings.get(context, R.string.background_shizuku_permission)
            else -> null
        }
    }

    fun ensureListeners() {
        if (listenersAdded) return
        listenersAdded = true
        runCatching {
            Shizuku.addBinderReceivedListenerSticky { onChanged() }
            Shizuku.addBinderDeadListener { channel = null; onChanged() }
            Shizuku.addRequestPermissionResultListener { _, _ -> onChanged() }
        }
    }

    fun requestPermission(): Boolean {
        if (!running()) return false
        return runCatching { Shizuku.requestPermission(PERMISSION_REQUEST_CODE); true }.getOrDefault(false)
    }

    /** Asks for the permission; [then] runs (main thread) once the person allows it. */
    fun requestPermission(then: () -> Unit): Boolean {
        if (!running()) return false
        val listener = object : Shizuku.OnRequestPermissionResultListener {
            override fun onRequestPermissionResult(requestCode: Int, grantResult: Int) {
                if (requestCode != GRANT_REQUEST_CODE) return
                Shizuku.removeRequestPermissionResultListener(this)
                onChanged()
                if (grantResult == PackageManager.PERMISSION_GRANTED) then()
            }
        }
        return runCatching {
            Shizuku.addRequestPermissionResultListener(listener)
            Shizuku.requestPermission(GRANT_REQUEST_CODE)
            true
        }.getOrElse {
            Shizuku.removeRequestPermissionResultListener(listener)
            false
        }
    }

    /** Binds the UserService (blocking, 15 s). Returns a live channel, or null with [reason]. */
    fun connect(): PrivilegedChannel? {
        channel?.takeIf { it.alive() }?.let { return it }
        if (!granted()) return null
        val latch = CountDownLatch(1)
        val holder = arrayOfNulls<IBinder>(1)
        val serviceArgs = args0
        val listener = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (connection !== this) return
                holder[0] = binder
                latch.countDown()
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                if (connection !== this) return
                channel = null
                onChanged()
            }
        }
        connection = listener
        args = serviceArgs
        main.post { runCatching { Shizuku.bindUserService(serviceArgs, listener) } }
        if (!latch.await(15, TimeUnit.SECONDS)) { disconnect(); return null }
        val remote = IPrivilegedDisplay.Stub.asInterface(holder[0]) ?: run { disconnect(); return null }
        // Probe to confirm identity and revision before use.
        val probe = runCatching { remote.execute(android.os.Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) }) }.getOrNull()
        if (probe?.getBoolean(Proto.OK) != true || probe.getString("revision") != Proto.REVISION) { disconnect(); return null }
        val value = ShizukuChannel(remote)
        channel = value
        return value
    }

    fun disconnect() {
        channel = null
        val conn = connection ?: return
        val serviceArgs = args
        connection = null
        args = null
        if (serviceArgs != null) {
            main.post { runCatching { Shizuku.unbindUserService(serviceArgs, conn, true) } }
        }
    }
}
