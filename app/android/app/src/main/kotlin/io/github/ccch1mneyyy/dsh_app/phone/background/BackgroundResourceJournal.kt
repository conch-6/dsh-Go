package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.Json
import java.util.UUID

/** Physical facts only. Its storage lock never calls a controller, Tasks, IO or UI. */
internal class BackgroundResourceJournal(
    private val read: () -> String?,
    private val commit: (String) -> Boolean,
    private val processInstance: String = PROCESS_INSTANCE,
) {
    data class Birth(val peer: String, val boot: String, val pid: Int, val uid: Int,
        val pidNsDev: Long, val pidNsIno: Long) {
        init {
            require(canonicalUuid(peer) && canonicalUuid(boot))
            require(pid > 0 && uid >= 0 && pidNsIno > 0)
        }
    }
    data class Record internal constructor(
        val owner: String, val process: String, val purpose: String,
        val birth: Birth, val viewport: String?, val displayId: Int? = null,
    )
    data class Snapshot(val state: String, val count: Int, val reason: String?,
        val storageRetry: Boolean)

    private val lock = Any()
    private var loaded = false
    private var attempted = false
    private var storageError: String? = null
    private var records = emptyList<Record>()
    // In-memory proofs belong to exact records; they are not reconstructed after a restart.
    private val completed = mutableSetOf<String>()
    @Volatile private var snapshot = Snapshot("loading", 0, null, true)

    init { require(canonicalUuid(processInstance)) }

    fun status(): Snapshot = snapshot
    fun load(): Boolean = synchronized(lock) { loadLocked() }
    private fun loadLocked(): Boolean {
        if (loaded) return true
        if (attempted) return false
        attempted = true
        return try {
            records = read()?.let(::decode) ?: emptyList()
            loaded = true
            storageError = null
            publish()
            true
        } catch (_: Exception) {
            storageError = "storageReadFailed"
            publish()
            false
        }
    }

    fun record(owner: String, purpose: String, birth: Birth, viewport: String?): Record {
        require(canonicalUuid(owner))
        require(purpose in setOf("task", "probe", "target"))
        require(if (purpose == "task") viewport in setOf("portrait", "landscape") else viewport == null)
        return Record(owner, processInstance, purpose, birth, viewport)
    }

    /** Keep even a failed-write candidate in memory: commit(false) cannot prove disk absence. */
    fun mark(record: Record): Boolean = synchronized(lock) {
        if (!loaded || storageError != null || completed.isNotEmpty() ||
            record.process != processInstance || record.displayId != null ||
            records.any { it.process != processInstance || it.owner == record.owner }) return false
        if (records.size >= LIMIT) return false
        persist(records + record, retainOnFailure = true)
    }

    /** The actual ID is known, even when persisting it fails. No caller may launch on failure. */
    fun allocated(record: Record, actualId: Int): Boolean = synchronized(lock) {
        if (!loaded || actualId <= 0 || record.process != processInstance || record.owner in completed) return false
        val current = records.singleOrNull { it.owner == record.owner } ?: return false
        if (!sameScope(current, record) || current.displayId != null) return false
        persist(records.map { if (it === current) it.copy(displayId = actualId) else it }, retainOnFailure = true)
    }

    /** Only after this original current-process IO has drained and proved unused or released. */
    fun closed(record: Record): Boolean = synchronized(lock) {
        if (!loaded || record.process != processInstance) return false
        val current = records.singleOrNull { it.owner == record.owner } ?: return true
        if (!sameScope(current, record)) return false
        completed.add(current.owner)
        persist(records.filterNot { it.owner in completed }, retainOnFailure = false)
    }

    /** The exact current-process snapshot, including an actual ID whose write failed, that a receipt must match. */
    fun current(record: Record): Record? = synchronized(lock) {
        if (!loaded || record.process != processInstance || record.owner in completed) null
        else records.singleOrNull { it.owner == record.owner }?.takeIf { sameScope(it, record) }
    }

    /** The caller first validates an independent recovery receipt against this exact snapshot. */
    fun recovered(record: Record): Boolean = synchronized(lock) {
        if (!loaded || record.process == processInstance) return false
        val current = records.singleOrNull { it.owner == record.owner } ?: return true
        if (current != record) return false
        completed.add(current.owner)
        persist(records.filterNot { it.owner in completed }, retainOnFailure = false)
    }

    /** One peerRetired receipt proves this whole captured group; retain every proof on write failure. */
    fun recoveredPeer(peer: String, expected: List<Record>): Boolean = synchronized(lock) {
        if (!loaded || expected.isEmpty() || expected.any { it.process == processInstance || it.birth.peer != peer }) return false
        val current = records.filter { it.birth.peer == peer }
        if (current.toSet() != expected.toSet()) return false
        completed.addAll(current.map { it.owner })
        persist(records.filterNot { it.owner in completed }, retainOnFailure = false)
    }

    /** No ACK/ignore path: only known-complete records are deleted. Unknown old records remain. */
    fun retryStorage(): Boolean = synchronized(lock) {
        if (!loaded) { attempted = false; return loadLocked() }
        if (storageError == null && completed.isEmpty()) return true
        persist(records.filterNot { it.owner in completed }, retainOnFailure = false)
    }

    fun oldRecords(): List<Record>? = synchronized(lock) {
        if (!loaded || storageError != null || completed.isNotEmpty()) null
        else records.filter { it.process != processInstance }
    }

    fun hasCurrentResources(): Boolean = synchronized(lock) {
        records.any { it.process == processInstance && it.owner !in completed }
    }

    private fun persist(next: List<Record>, retainOnFailure: Boolean): Boolean {
        val ok = try { commit(encode(next)) } catch (_: Exception) { false }
        if (ok) {
            records = next
            completed.retainAll(next.map { it.owner }.toSet())
            storageError = null
        } else {
            if (retainOnFailure) records = next
            storageError = "storageWriteFailed"
        }
        publish()
        return ok
    }

    private fun publish() {
        val old = records.any { it.process != processInstance }
        snapshot = Snapshot(
            when {
                storageError != null || completed.isNotEmpty() -> "error"
                !loaded -> "loading"
                old -> "pending"
                else -> "clear"
            }, records.size, storageError ?: if (old) "oldResources" else null,
            !loaded || storageError != null || completed.isNotEmpty(),
        )
    }

    private fun encode(values: List<Record>): String = Json.write(mapOf(
        "version" to 1, "records" to values.map { r -> mapOf(
            "owner" to r.owner, "processInstance" to r.process, "purpose" to r.purpose,
            "recoveryPeer" to r.birth.peer, "recoveryBoot" to r.birth.boot,
            "recoveryPid" to r.birth.pid, "recoveryUid" to r.birth.uid,
            "recoveryPidNsDev" to r.birth.pidNsDev, "recoveryPidNsIno" to r.birth.pidNsIno,
            "viewport" to r.viewport, "displayId" to r.displayId,
            "phase" to if (r.displayId == null) "intent" else "allocated",
        ) }))

    private fun decode(raw: String): List<Record> {
        val root = Json.parse(raw) as? Map<*, *> ?: error("format")
        require(root.keys == setOf("version", "records") && root["version"] == 1L)
        val list = root["records"] as? List<*> ?: error("records")
        require(list.size <= LIMIT)
        val result = list.map { value ->
            val m = value as? Map<*, *> ?: error("record")
            require(m.keys == RECORD_KEYS)
            fun string(key: String): String = m[key] as? String ?: error("string")
            fun uuid(key: String): String = string(key).also { require(canonicalUuid(it)) }
            fun number(key: String): Long = m[key] as? Long ?: error("number")
            fun integer(key: String): Int = number(key).also {
                require(it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong())
            }.toInt()
            val purpose = string("purpose")
            require(purpose in setOf("task", "probe", "target"))
            val viewport = m["viewport"]
            require(if (purpose == "task") viewport in setOf("portrait", "landscape") else viewport == null)
            val id = m["displayId"]?.let {
                (it as? Long)?.takeIf { n -> n in 1..Int.MAX_VALUE.toLong() }?.toInt() ?: error("display")
            }
            require(m["phase"] == if (id == null) "intent" else "allocated")
            Record(uuid("owner"), uuid("processInstance"), purpose,
                Birth(uuid("recoveryPeer"), uuid("recoveryBoot"), integer("recoveryPid"),
                    integer("recoveryUid"), number("recoveryPidNsDev"), number("recoveryPidNsIno")),
                viewport as String?, id)
        }
        require(result.map { it.owner }.distinct().size == result.size)
        require(result.groupBy { it.birth.peer }.values.all { group -> group.map { it.birth }.distinct().size == 1 })
        return result
    }

    private fun sameScope(a: Record, b: Record): Boolean =
        a.copy(displayId = null) == b.copy(displayId = null)

    companion object {
        private const val LIMIT = 256
        private val PROCESS_INSTANCE = UUID.randomUUID().toString()
        private val RECORD_KEYS = setOf("owner", "processInstance", "purpose", "recoveryPeer",
            "recoveryBoot", "recoveryPid", "recoveryUid", "recoveryPidNsDev", "recoveryPidNsIno",
            "viewport", "displayId", "phase")
        private fun canonicalUuid(value: String): Boolean =
            runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
        // l10n:keep agent physical recovery refusal
        const val REFUSAL = "旧后台资源尚未核验，本次未执行。请在手机操控页处理后台资源恢复。"
    }
}
