package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.UUID

/** The one settings probe's original I/O lane. A retry can only release this same peer/owner. */
internal class BackgroundGateCall<C : Any>(
    val peer: C,
    // Probe's mayApply captures the original UI/selection generation; retry ignores its liveness.
    val probe: BackgroundGateState.Probe,
    journal: BackgroundResourceJournal,
) {
    val io = BackgroundDisplayIo<C>()
    val resource = BackgroundResourceScope(io, journal, "probe")
    val handle: String = UUID.randomUUID().toString()
    private val lock = Any()
    private var probing = true
    private var phase = "pending"

    fun status(peerAlive: Boolean): Map<String, Any?> = synchronized(lock) {
        mapOf("v" to 1, "state" to phase, "handle" to if (phase == "idle") null else handle,
            "canRetry" to (!probing && phase == "unknown" && (peerAlive || resource.physicalComplete)))
    }

    /** Called only after the original call has drained, including a lost/throwing reply. */
    fun finishProbeAndCleanup(release: (C, String) -> Boolean): Boolean {
        synchronized(lock) {
            if (!probing) return false
            probing = false
            phase = "cleaning"
        }
        return releaseClaimed(release)
    }

    /** A UI retry cannot overtake initial cleanup or clear an already completed caller's slot. */
    fun retryCleanup(release: (C, String) -> Boolean): Boolean {
        synchronized(lock) {
            if (probing || phase != "unknown") return false
            phase = "cleaning"
        }
        return releaseClaimed(release)
    }

    private fun releaseClaimed(release: (C, String) -> Boolean): Boolean {
        io.seal()
        val released = try { resource.cleanup { release(it, io.owner) } } catch (_: Exception) { false }
        synchronized(lock) { phase = if (released) "idle" else "unknown" }
        return released
    }
}
