// Root app_process path. Magisk/KernelSU/APatch command syntax checked against upstream
// source; authorization UI, SELinux and display behavior have NOT been verified on devices.
package io.github.ccch1mneyyy.dsh_app.phone.background

import android.content.Context
import android.os.Bundle
import android.os.Process
import java.io.IOException

/**
 * su runs only from [start]: behind an explicit user action, or, once the person turned on
 * keeping root, from the keeper. Tasks and [grantSecureSettings] only use what a start left alive.
 */
class RootStarter(private val context: Context, private val onChanged: () -> Unit) {
    private val guard = Any()
    private val startLock = Any()
    private val state = RootState()
    private var channel: RootChannel? = null
    private var pending: RootProcess? = null
    private var pendingAllowed: (() -> Boolean)? = null

    fun status(): RootStatus = synchronized(guard) {
        discardDead()
        state.status()
    }

    fun connect(): PrivilegedChannel? = synchronized(guard) {
        discardDead()
        channel
    }

    /**
     * [mayStart] (a lock-free read of the caller's UI or explicit keep ticket) is checked under the guard [disconnect]
     * takes, so a cancel either comes first and nothing starts, or ends this start's ticket.
     */
    fun start(mayStart: () -> Boolean = { true }): PrivilegedChannel? = synchronized(startLock) start@{
        val ticket = synchronized(guard) {
            discardDead()
            channel?.let { return@start if (mayStart()) it else null }
            (state.beginIfAllowed(mayStart) ?: return@start null).also { pendingAllowed = mayStart }
        }
        onChanged()
        val stillAccepted = synchronized(guard) {
            if (!state.current(ticket) || !mayStart()) {
                if (state.current(ticket)) { pendingAllowed = null; state.disconnect() }
                false
            } else true
        }
        if (!stillAccepted) { onChanged(); return@start null }
        val info = context.applicationInfo
        val process = try {
            RootProcess.launch(RootCommands.appProcess(info.sourceDir, info.splitSourceDirs?.toList().orEmpty()))
        } catch (error: Exception) {
            synchronized(guard) { if (state.current(ticket)) { pendingAllowed = null; state.finish(ticket, reason(error)) } }
            onChanged()
            return@start null
        }
        // Registered, disconnect() closes it mid-authorization; already cancelled, it closes now.
        synchronized(guard) { if (state.current(ticket)) pending = process else process.close() }
        val failure = try {
            val probe = Bundles.unmarshal(process.exchange(Bundles.marshal(Bundle().apply {
                putString(Proto.OP, Proto.OP_PROBE)
            }), START_TIMEOUT_MS))
            when {
                !probe.getBoolean(Proto.OK) -> "rootStartFailed"
                !RootProbe.accepted(true, probe.getInt(Proto.UID, -1), probe.getString("revision"), Proto.REVISION) -> "rootIdentityMismatch"
                else -> null
            }
        } catch (error: Exception) {
            reason(error)
        }
        val result = synchronized(guard) {
            if (state.current(ticket) && !mayStart()) state.disconnect()
            pending = null
            pendingAllowed = null
            if (state.finish(ticket, failure) && failure == null) {
                RootChannel(process) { channelFailed(process, it) }.also { channel = it }
            } else null
        }
        if (result == null) process.close()
        onChanged()
        result
    }

    /** The fixed grant uses the connected root process; it never starts or retries su. */
    fun grantSecureSettings(): Boolean {
        val current = connect() ?: return false
        val ok = current.execute(Bundle().apply {
            putString(Proto.OP, Proto.OP_GRANT_SECURE_SETTINGS)
            putInt(Proto.USER, Process.myUid() / 100000)
        }).getBoolean(Proto.OK)
        if (!ok) synchronized(guard) {
            if (channel === current) state.note("rootGrantFailed")
        }
        onChanged()
        return ok
    }

    /** Revokes only a still-pending attempt whose own caller no longer wants it. */
    fun cancelUnwantedPending() {
        val cancelled = synchronized(guard) {
            val allowed = pendingAllowed
            if (allowed == null || allowed()) false else {
                state.disconnect()
                pendingAllowed = null
                pending?.close(); pending = null
                true
            }
        }
        if (cancelled) onChanged()
    }

    fun disconnect() {
        synchronized(guard) {
            state.disconnect()
            pendingAllowed = null
            pending?.close(); pending = null
            channel?.close(); channel = null
        }
        onChanged()
    }

    private fun discardDead() {
        if (channel?.alive() == false) {
            channel?.close(); channel = null
            state.disconnect()
        }
    }

    private fun channelFailed(process: RootProcess, failure: String) {
        synchronized(guard) {
            if (channel?.process !== process) return
            channel = null
            state.disconnect()
            state.note(failure)
        }
        onChanged()
    }

    companion object {
        // App policy, not the managers' own authorization timeouts.
        const val START_TIMEOUT_MS = 30_000L
        private fun reason(error: Exception): String =
            error.message.takeIf { error is IOException && it in setOf("rootTimeout", "rootCancelled") } ?: "rootStartFailed"
    }
}

private class RootChannel(
    val process: RootProcess,
    private val onFailure: (String) -> Unit,
) : PrivilegedChannel {
    override fun alive(): Boolean = process.alive()
    override fun close() = process.close()
    override fun execute(request: Bundle): Bundle = try {
        Bundles.unmarshal(process.exchange(Bundles.marshal(request), 30_000))
    } catch (error: Exception) {
        val timeout = error is IOException && error.message == "rootTimeout"
        process.close()
        onFailure(if (timeout) "rootTimeout" else "rootDisconnected")
        Bundle().apply {
            putBoolean(Proto.OK, false)
            putString(Proto.ERROR, if (timeout) "timeout" else "deviceUnavailable")
            if (!timeout) putString(Proto.ERROR_DETAIL, "root ${error.javaClass.simpleName}")
        }
    }
}
