package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Core serializes access. Shutdown retains the original encoder until it really terminates. */
internal class BackgroundPreviewWorker {
    private var worker: ExecutorService? = null
    fun acquire(): ExecutorService? {
        val old = worker
        if (old != null && !old.isTerminated) return old.takeUnless { it.isShutdown }
        return Executors.newSingleThreadExecutor { job -> Thread(job, "dsh-preview").apply { isDaemon = true } }
            .also { worker = it }
    }

    /** A release receipt must observe the encoder's real termination, not just a queued shutdown. */
    fun stop() {
        val old = worker ?: return
        old.shutdown()
        runCatching { old.awaitTermination(STOP_TIMEOUT_MS, TimeUnit.MILLISECONDS) }
    }

    fun drained(): Boolean {
        val old = worker ?: return true
        if (!old.isTerminated && old.isShutdown) {
            runCatching { old.awaitTermination(DRAIN_TIMEOUT_MS, TimeUnit.MILLISECONDS) }
        }
        if (!old.isTerminated) return false
        worker = null
        return true
    }

    private companion object {
        const val STOP_TIMEOUT_MS = 1_000L
        const val DRAIN_TIMEOUT_MS = 250L
    }
}
