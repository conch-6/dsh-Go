package io.github.ccch1mneyyy.dsh_app.phone.background

/** The real Host admission table. No platform work runs while its monitor is held. */
internal class OwnerScopes<C : Any, R : Any>(private val limit: Int = 3, private val lifetime: Int = 256) {
    class Record<C>(val owner: String, val maintenance: Boolean, val core: C) {
        internal var busy = false
        internal var closing = false
    }
    sealed class Entry<C, R> {
        class Acquired<C, R>(val record: Record<C>) : Entry<C, R>()
        class Completed<C, R>(val receipt: R) : Entry<C, R>()
        class Refused<C, R>(val code: String, val unknown: Boolean) : Entry<C, R>()
    }
    private val lock = Any()
    private val active = linkedMapOf<String, Record<C>>()
    private val completed = linkedMapOf<String, R>()
    private val retiredOwners = hashSetOf<String>()
    private var retired = false
    private var global = false
    private var mode: Boolean? = null

    fun enter(owner: String, opening: Boolean, maintenance: Boolean, release: Boolean,
              create: () -> C): Entry<C, R> = synchronized(lock) {
        val known = active.containsKey(owner) || completed.containsKey(owner) || owner in retiredOwners
        fun no(code: String) = Entry.Refused<C, R>(code, !known)
        if (retired) return no("peerRetired")
        if (mode == false) return no("scopeModeMismatch")
        if (global) return no("scopeBusy")
        val done = completed[owner]
        if (done != null) return if (release) Entry.Completed(done) else no("identityChanged")
        var record = active[owner]
        if (record == null) {
            if (!opening) return no("identityChanged")
            if (active.size + completed.size >= lifetime) return no("scopeHistoryFull")
            if (active.size >= limit) return no("scopeCapacity")
            if (active.values.any { it.maintenance } || maintenance && active.isNotEmpty()) return no("scopeBusy")
            record = Record(owner, maintenance, create())
            active[owner] = record
            mode = true
        }
        if (release) record.closing = true
        if (record.busy) return no(if (release) "releasePending" else "scopeBusy")
        if (record.closing && !release) return no("releasePending")
        record.busy = true
        Entry.Acquired(record)
    }

    fun leave(record: Record<C>, receipt: R? = null) = synchronized(lock) {
        check(active[record.owner] === record && record.busy)
        if (receipt != null) {
            check(record.closing)
            completed[record.owner] = receipt
            active.remove(record.owner)
        } else record.busy = false
    }

    fun enterGlobal(legacyResource: Boolean = false): String? = synchronized(lock) {
        if (retired) return "peerRetired"
        if (global || active.isNotEmpty()) return "scopeBusy"
        if (legacyResource && mode == true) return "scopeModeMismatch"
        if (legacyResource) mode = false
        global = true
        null
    }

    /** Permanent seal is published even when an already admitted body must finish first. */
    fun beginRetire(): List<Record<C>>? = synchronized(lock) {
        retired = true
        retiredOwners.addAll(active.keys)
        retiredOwners.addAll(completed.keys)
        if (global || active.values.any { it.busy }) return null
        global = true
        active.values.onEach { it.closing = true }.toList()
    }
    fun finishRetire(complete: Boolean) = synchronized(lock) {
        check(retired && global)
        if (complete) { active.clear(); completed.clear() }
        global = false
    }
    fun leaveGlobal() = synchronized(lock) { check(global); global = false }
}
