package io.github.ccch1mneyyy.dsh_app.phone.background

/** Capability facts and known transport failures; an untested channel is still unknown. */
internal class BackgroundGateState {
    data class Snapshot(
        val trustedDisplayOk: Boolean? = null,
        val injectOk: Boolean? = null,
        val injectError: String? = null,
        val gateDetail: String? = null,
        val connectionError: Int? = null,
    )

    class Probe internal constructor(internal val mayApply: () -> Boolean)
    private var probe: Probe? = null
    private var failedChannel: Any? = null

    @Volatile var snapshot = Snapshot()
        private set

    @Synchronized fun reset() { probe = null; failedChannel = null; snapshot = Snapshot() }

    /** A deliberate retry can enter even after a failure; it does not erase capability facts. */
    @Synchronized fun begin(mayApply: () -> Boolean): Probe? {
        if (!mayApply()) return null
        failedChannel = null
        if (snapshot.connectionError != null) snapshot = snapshot.copy(connectionError = null)
        return Probe(mayApply).also { probe = it }
    }

    /** Revoke an old UI attempt before its worker returns, without forgetting completed facts. */
    @Synchronized fun cancelUnwantedPending() {
        if (probe?.mayApply?.invoke() == false) probe = null
    }

    @Synchronized fun current(owner: Probe): Boolean = probe === owner && owner.mayApply()

    @Synchronized fun failed(owner: Probe, reason: Int, channel: Any? = null): Boolean {
        if (!current(owner)) return false
        failedChannel = channel
        snapshot = snapshot.copy(connectionError = reason)
        return true
    }

    /** A connection can replace only the failure observed before that attempt started. */
    @Synchronized fun connected(observed: Snapshot, channel: Any) {
        if (snapshot === observed && snapshot.connectionError != null && failedChannel !== channel) {
            probe = null
            failedChannel = null
            snapshot = snapshot.copy(connectionError = null)
        }
    }

    /** False means the probe did not run, so none of the cached facts may be replaced. */
    @Synchronized fun update(owner: Probe, ok: Boolean, error: String?, injectOk: Boolean?, injectError: String?, detail: String?): Boolean {
        if (!current(owner) || error == "probeBusy") return false
        failedChannel = null
        snapshot = Snapshot(ok, injectOk, if (injectOk == false) injectError else null, detail)
        return true
    }
}
