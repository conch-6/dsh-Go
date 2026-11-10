package io.github.ccch1mneyyy.dsh_app.update.privileged

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Reads while writing: a package-service rejection must not deadlock a full adb pipe. */
internal object SelfUpdateStreams {
    fun exchange(
        apk: InputStream,
        size: Long,
        sha256: String,
        input: InputStream,
        output: OutputStream,
        timeoutMs: Long = SelfUpdatePolicy.INSTALL_TIMEOUT_MS,
        exitCode: () -> Int? = { null },
        close: () -> Unit,
    ): SelfUpdateReceipt {
        val worker = Executors.newFixedThreadPool(2) { task ->
            Thread(task, "dsh-update-stream").apply { isDaemon = true }
        }
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        val writer = worker.submit<Unit> {
            SelfUpdatePolicy.copyVerified(apk, output, size, sha256)
            // cmd package consumes exactly -S bytes. Closing adb stdin closes the entire stream.
            output.flush()
        }
        val reader = worker.submit<Pair<String, Boolean>> {
            val bytes = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            var overflow = false
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                val room = SelfUpdatePolicy.MAX_OUTPUT_BYTES - bytes.size()
                if (n > room) overflow = true
                if (room > 0) bytes.write(buffer, 0, minOf(n, room))
            }
            bytes.toString("UTF-8") to !overflow
        }
        return try {
            val (text, complete) = reader.get(remaining(deadline), TimeUnit.NANOSECONDS)
            val receipt = SelfUpdatePolicy.interpretOutput(text, complete, exitCode())
            // An explicit final rejection is decisive even if it made a blocked writer fail.
            if (receipt.status != "success" && !receipt.outcomeUnknown) receipt else {
                writer.get(remaining(deadline), TimeUnit.NANOSECONDS)
                receipt
            }
        } catch (error: Exception) {
            if (error is InterruptedException) Thread.currentThread().interrupt()
            SelfUpdatePolicy.unknown()
        } finally {
            runCatching { close() }
            runCatching { apk.close() }
            writer.cancel(true)
            reader.cancel(true)
            worker.shutdownNow()
        }
    }

    private fun remaining(deadline: Long): Long = (deadline - System.nanoTime()).coerceAtLeast(1)
}
