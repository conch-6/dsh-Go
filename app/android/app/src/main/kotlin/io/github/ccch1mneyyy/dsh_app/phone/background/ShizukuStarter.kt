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
import rikka.sui.Sui

class ShizukuStarter(private val context: Context, private val onChanged: () -> Unit) {
    companion object {
        const val PACKAGE = "moe.shizuku.privileged.api"
        private const val PERMISSION_REQUEST_CODE = 4601

        /** 自动恢复无障碍's request, told apart from 不打扰模式's. */
        private const val GRANT_REQUEST_CODE = 4602
    }

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var channel: ShizukuChannel? = null
    private val guard = Any()
    private class Binding(val mayStart: () -> Boolean, val args: Shizuku.UserServiceArgs) {
        val latch = CountDownLatch(1)
        var worker: Thread? = Thread.currentThread()
        var valid = true
        var bound = false // main-thread bind was issued, even if the remote call failed
        var cleaning = false
        var whenAvailable: (() -> Unit)? = null
        var binder: IBinder? = null
        lateinit var listener: ServiceConnection
    }
    private var binding: Binding? = null
    @Volatile private var listenersAdded = false

    private val args0: Shizuku.UserServiceArgs
        get() = Shizuku.UserServiceArgs(ComponentName(context, PrivilegedDisplayService::class.java))
            .tag("dsh.vdisplay").processNameSuffix("vdisplay").version(1).daemon(false)

    private fun appInstalled(): Boolean =
        runCatching { context.packageManager.getApplicationInfo(PACKAGE, 0); true }.getOrDefault(false)

    fun running(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    fun granted(): Boolean = runCatching {
        running() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    // ShizukuProvider has already run Sui.init() before the Activity; isSui() only reads its result.
    fun status(): ShizukuStatus = ShizukuStatus.fromFacts(appInstalled(), Sui.isSui(), running(), granted())

    fun uid(): Int = runCatching { Shizuku.getUid() }.getOrDefault(-1)

    /** A one-line reason when not ready, else null. */
    fun reason(): String? {
        val status = status()
        val sui = status.provider == ShizukuStatus.SUI
        return when {
            !status.installed -> AppStrings.get(context, R.string.background_shizuku_missing)
            !status.running -> AppStrings.get(context,
                if (sui) R.string.background_sui_stopped else R.string.background_shizuku_stopped)
            !status.granted -> AppStrings.get(context,
                if (sui) R.string.background_sui_permission else R.string.background_shizuku_permission)
            else -> null
        }
    }

    fun ensureListeners() {
        if (listenersAdded) return
        listenersAdded = true
        runCatching {
            Shizuku.addBinderReceivedListenerSticky { onChanged() }
            Shizuku.addBinderDeadListener { disconnect(); onChanged() }
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

    /** The 15 s bind wait does not impose a deadline on Binder PROBE or remote teardown. */
    fun connect(whenAvailable: (() -> Unit)? = null, mayStart: () -> Boolean = { true }): PrivilegedChannel? {
        if (!granted()) return null
        val owner = synchronized(guard) {
            if (!mayStart()) return null
            channel?.takeIf { it.alive() }?.let { return it }
            // An old service/cleanup still owns this fixed tag. Never replace it underneath unbind.
            binding?.let {
                if (whenAvailable != null) it.whenAvailable = whenAvailable
                if (it.worker == null) retire(it)
                return null
            }
            Binding(mayStart, args0).also { binding = it }
        }
        owner.listener = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                synchronized(guard) {
                    if (binding !== owner || !owner.valid) return
                    owner.binder = binder
                    owner.latch.countDown()
                }
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                synchronized(guard) { if (binding === owner) retire(owner) }
                onChanged()
            }
        }
        main.post {
            val bind = synchronized(guard) {
                if (!owner.valid || !owner.mayStart()) false else { owner.bound = true; true }
            }
            if (bind) runCatching { Shizuku.bindUserService(owner.args, owner.listener) }
                .onFailure { owner.latch.countDown() }
            else owner.latch.countDown()
        }
        try {
            if (!owner.latch.await(15, TimeUnit.SECONDS)) return null
            val binder = synchronized(guard) {
                if (!owner.valid || !owner.mayStart()) return null
                owner.binder
            }
            val remote = IPrivilegedDisplay.Stub.asInterface(binder) ?: return null
            val probe = remote.execute(android.os.Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
            if (!probe.getBoolean(Proto.OK) || probe.getString("revision") != Proto.REVISION) return null
            return synchronized(guard) {
                if (!owner.valid || !owner.mayStart()) return null
                ShizukuChannel(remote).also { channel = it }
            }
        } catch (e: Exception) {
            if (e is InterruptedException) Thread.currentThread().interrupt()
            return null
        } finally {
            val available = synchronized(guard) {
                owner.worker = null
                if (!owner.valid || channel == null) { retire(owner); null }
                else owner.whenAvailable.also { owner.whenAvailable = null }
            }
            available?.invoke()
            onChanged()
        }
    }

    fun cancelUnwantedPending() {
        synchronized(guard) {
            val owner = binding ?: return
            if (channel == null && !owner.mayStart()) retire(owner)
        }
    }

    fun disconnectIfCurrent(expected: PrivilegedChannel?) {
        if (expected == null) return
        synchronized(guard) {
            if (channel === expected) binding?.let { retire(it) }
        }
    }

    fun disconnect() {
        synchronized(guard) { binding?.let { retire(it) } }
    }

    // Caller holds guard. A pending Binder operation must finish before its tag may be reused.
    private fun retire(owner: Binding) {
        owner.valid = false
        channel = null
        owner.latch.countDown()
        owner.worker?.interrupt()
        if (owner.worker != null || owner.cleaning) return
        owner.cleaning = true
        main.post {
            var detached = true
            if (owner.bound) {
                // API 13.1.5 remove=true kills the service but leaves its local callback cache until
                // a later death callback. Detach that cache first, before reusing this fixed tag.
                detached = runCatching { Shizuku.unbindUserService(owner.args, owner.listener, false) }.isSuccess
                runCatching { Shizuku.unbindUserService(owner.args, owner.listener, true) }
            }
            val available = synchronized(guard) {
                if (detached) {
                    binding = null
                    owner.whenAvailable.also { owner.whenAvailable = null }
                } else {
                    owner.cleaning = false // retry teardown before any new same-tag bind
                    null
                }
            }
            available?.invoke()
            onChanged()
        }
    }
}
