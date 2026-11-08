package io.github.ccch1mneyyy.dsh_app.phone.background

/**
 * The original owner's durable allocation barrier. Calls begin/allocated from this IO's call body;
 * cleanup is outside that body and uses the same IO's actual drain/release result.
 * No callbacks or storage run under the IO's short lock.
 */
internal class BackgroundResourceScope<C : Any>(
    private val io: BackgroundDisplayIo<C>,
    private val journal: BackgroundResourceJournal,
    private val purpose: String,
    private val viewport: String? = null,
) {
    private var record: BackgroundResourceJournal.Record? = null
    private var intentCommitted = false
    private var allocationExamined = false
    @Volatile var allocationReady = false
        private set
    @Volatile var physicalComplete = false
        private set

    /** Exactly one attempt on this original owner, including a failed intent write. */
    fun begin(birth: BackgroundResourceJournal.Birth): Boolean {
        if (record != null || physicalComplete) return false
        val original = journal.record(io.owner, purpose, birth, viewport)
        record = original
        intentCommitted = journal.mark(original)
        return intentCommitted
    }

    /** Invoke only after matching the original owner-scoped response and actual positive ID.
     * A failed commit or late/cancelled result never turns a pinned resource into ready.
     */
    fun allocated(actualId: Int, stillCurrent: () -> Boolean): Boolean {
        val original = record ?: return false
        if (!intentCommitted || allocationExamined || physicalComplete) return false
        allocationExamined = true
        if (!journal.allocated(original, actualId) || !stillCurrent()) return false
        allocationReady = true
        return true
    }

    /** io.release returns true only after real drain and either proven unused or strict release.
     * It caches physical completion. Repeating this method after a storage failure does not
     * allocate, launch, verify, inject or request another physical release.
     */
    fun cleanup(release: (C) -> Boolean): Boolean {
        if (!io.release(release)) return false
        allocationReady = false
        physicalComplete = true
        val original = record ?: return true
        return journal.closed(original)
    }

    /** The original pin died before strict release. On this same drained lane, only an independent
     * receipt for the exact journal snapshot replaces RELEASE; nothing is sent to the dead pin.
     */
    fun recover(dead: (C) -> Boolean, verify: (BackgroundResourceJournal.Record) -> Boolean): Boolean =
        cleanup { pinned -> dead(pinned) && record?.let(journal::current)?.let(verify) == true }
}
