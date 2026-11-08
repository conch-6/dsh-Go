package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Core serializes access. Shutdown retains the original encoder until it really terminates. */
internal class BackgroundPreviewWorker {
    private var worker: ExecutorService? = null
    fun acquire(): ExecutorService? {
        val old = worker
        if (old != null && !old.isTerminated) return old.takeUnless { it.isShutdown }
        return Executors.newSingleThreadExecutor { job -> Thread(job, "dsh-preview").apply { isDaemon = true } }
            .also { worker = it }
    }
    fun stop() { worker?.shutdown() }
    fun drained(): Boolean {
        val old = worker ?: return true
        if (!old.isTerminated) return false
        worker = null
        return true
    }
}
