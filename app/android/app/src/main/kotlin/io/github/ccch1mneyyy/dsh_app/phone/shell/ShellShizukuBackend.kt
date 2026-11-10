package io.github.ccch1mneyyy.dsh_app.phone.shell

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

internal class ShellShizukuBackend(private val context: Context, private val onChanged: () -> Unit) {
    private val guard = Any()
    private val main = Handler(Looper.getMainLooper())
    private var current: Binding? = null
    @Volatile private var channel: ShellLink? = null

    private class Binding(val wanted: () -> Boolean, val args: Shizuku.UserServiceArgs) {
        val latch = CountDownLatch(1)
        var valid = true
        var worker = true
        var bound = false
        var cleaning = false
        var binder: IBinder? = null
        lateinit var listener: ServiceConnection
    }

    init {
        runCatching {
            Shizuku.addBinderDeadListener { disconnect(); onChanged() }
            Shizuku.addBinderReceivedListener { onChanged() }
            Shizuku.addRequestPermissionResultListener { code, _ ->
                if (code == REQUEST_CODE) { if (!granted()) disconnect(); onChanged() }
            }
        }
    }

    fun status(): Map<String, Any?> = mapOf(
        "installed" to (runCatching { context.packageManager.getApplicationInfo("moe.shizuku.privileged.api", 0); true }.getOrDefault(false) || Sui.isSui()),
        "running" to running(), "granted" to granted(),
    )
    private fun running(): Boolean = Shizuku.getBinder()?.isBinderAlive == true
    private fun granted(): Boolean = runCatching {
        running() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    fun requestPermission(): Boolean = running() && runCatching {
        main.post { runCatching { Shizuku.requestPermission(REQUEST_CODE) } }
        true
    }.getOrDefault(false)

    fun connect(wanted: () -> Boolean): ShellConnection {
        if (!granted()) return ShellConnection(errorCode = when {
            status()["installed"] != true -> "shizukuMissing"
            !running() -> "shizukuStopped"
            else -> "permissionRequired"
        })
        val binding = synchronized(guard) {
            if (!wanted()) return ShellConnection(errorCode = "cancelled")
            channel?.takeIf { it.alive() }?.let { return ShellConnection(it) }
            current?.let { retire(it); return ShellConnection(errorCode = "busy") }
            Binding(wanted, Shizuku.UserServiceArgs(ComponentName(context, AndroidShellService::class.java))
                .tag(ShellProtocol.TAG).processNameSuffix("android_shell").version(1).daemon(false)).also { current = it }
        }
        binding.listener = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                synchronized(guard) {
                    if (current !== binding || !binding.valid) return
                    binding.binder = binder; binding.latch.countDown()
                }
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                synchronized(guard) { if (current === binding) retire(binding) }
                onChanged()
            }
        }
        main.post {
            synchronized(guard) {
                if (!binding.valid || !binding.wanted()) { binding.latch.countDown(); return@post }
                binding.bound = true
            }
            runCatching { Shizuku.bindUserService(binding.args, binding.listener) }
                .onFailure { binding.latch.countDown() }
        }
        var candidate: ShellLink? = null
        return try {
            if (!binding.latch.await(15, TimeUnit.SECONDS)) return ShellConnection(errorCode = "connectFailed")
            val binder = synchronized(guard) {
                if (!binding.valid || !wanted()) return ShellConnection(errorCode = "cancelled")
                binding.binder ?: return ShellConnection(errorCode = "connectFailed")
            }
            val remote = IAndroidShell.remote(binder)
            candidate = ShellLink("shizuku", { remote.execute(it) }, { binder.isBinderAlive }, {
                synchronized(guard) { if (current === binding) retire(binding) }
            })
            if (!candidate.probe()) return ShellConnection(errorCode = "identityChanged")
            synchronized(guard) {
                if (!binding.valid || !wanted()) return ShellConnection(errorCode = "cancelled")
                channel = candidate
                ShellConnection(candidate)
            }
        } catch (_: Exception) { ShellConnection(errorCode = "connectFailed") }
        finally {
            synchronized(guard) {
                binding.worker = false
                if (channel !== candidate || !binding.valid || candidate == null) { candidate?.close(); retire(binding) }
            }
            onChanged()
        }
    }

    fun disconnect() { synchronized(guard) { current?.let { retire(it) } } }

    private fun retire(binding: Binding) {
        binding.valid = false
        binding.latch.countDown()
        channel?.close(); channel = null
        if (binding.worker || binding.cleaning) return
        binding.cleaning = true
        main.post {
            var detached = true
            if (binding.bound) {
                detached = runCatching { Shizuku.unbindUserService(binding.args, binding.listener, false) }.isSuccess
                runCatching { Shizuku.unbindUserService(binding.args, binding.listener, true) }
            }
            synchronized(guard) {
                if (detached && current === binding) current = null else binding.cleaning = false
            }
            onChanged()
        }
    }

    private companion object { const val REQUEST_CODE = 4611 }
}
