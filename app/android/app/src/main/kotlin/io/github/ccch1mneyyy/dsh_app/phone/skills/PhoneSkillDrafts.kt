package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.runtime.PhoneSkillInstallResult
import io.github.ccch1mneyyy.dsh_app.runtime.PhoneSkillWrite
import java.lang.ref.WeakReference
import java.text.Normalizer
import java.util.UUID

/** One local editor. Manager -> write is the only nested lock order; never calls Runtime or performs IO. */
internal class PhoneSkillDrafts(private val newId: () -> String = { UUID.randomUUID().toString().replace("-", "") }) {
    class Client internal constructor(internal val issuer: Any) { internal var active = true }
    private val issuer = Any()
    @Synchronized fun attachClient(): Client = Client(issuer)

    enum class Code { STALE, BUSY, CONFIRMATION_REQUIRED, UNAVAILABLE, INVALID, SENSITIVE, TOO_LARGE,
        NO_HOME, CONFLICT, IO, CANNOT_CANCEL }
    data class Candidate(val owner: PhoneTaskTrace.OwnerKey, val steps: Int)
    data class Edit(val goal: String, val prerequisites: String, val checkpoints: List<String>, val stepOrder: List<Int>)
    data class View(val draftId: String, val owner: PhoneTaskTrace.OwnerKey, val revision: Long,
        val skillName: String, val markdown: String, val stepOrder: List<Int>, val parameterizedFields: List<String>,
        val phase: PhoneSkillWrite.Phase?)
    sealed interface Reply
    sealed interface SaveReply
    data class Shown(val view: View) : Reply
    data class Rejected(val code: Code) : Reply, SaveReply
    data class Saved(val name: String, val relativePath: String) : Reply, SaveReply
    data object Discarded : Reply
    data class Started(val write: PhoneSkillWrite) : SaveReply
    /** Already queued: the caller must not invoke Runtime a second time. */
    data class Existing(val write: PhoneSkillWrite) : SaveReply
    private class Editor(val id: String, val client: Client, val source: PhoneTaskTrace.Snapshot,
        var document: PhoneSkillDraft.Ready, var order: List<Int>) {
        var revision = 1L
        var parameters = emptyList<String>()
        var write: PhoneSkillWrite? = null
        var retired = false
    }
    private data class Receipt(val owner: PhoneTaskTrace.OwnerKey, val value: Saved, val client: Client,
        val write: WeakReference<PhoneSkillWrite>)
    private val candidates = LinkedHashMap<PhoneTaskTrace.OwnerKey, PhoneTaskTrace.Snapshot>()
    private val receipts = LinkedHashMap<String, Receipt>()
    private var editor: Editor? = null
    private var epoch = 0L

    /** Capture when the native task starts, never when its delayed completion callback arrives. */
    @Synchronized fun currentEpoch(): Long = epoch

    @Synchronized fun offer(expectedEpoch: Long, snapshot: PhoneTaskTrace.Snapshot): Boolean {
        if (expectedEpoch != epoch || !snapshot.canDraft || snapshot.steps.size > PhoneTaskTrace.MAX_STEPS ||
            receipts.values.any { it.owner == snapshot.owner }) return false
        candidates[snapshot.owner] = snapshot.copy(steps = snapshot.steps.toList())
        while (candidates.size > MAX_CANDIDATES) candidates.remove(candidates.keys.first())
        return true
    }

    @Synchronized fun candidates(): List<Candidate> = candidates.values.map { Candidate(it.owner, it.steps.size) }

    @Synchronized fun open(client: Client, owner: PhoneTaskTrace.OwnerKey, userConfirmed: Boolean): Reply {
        if (!attached(client)) return Rejected(Code.STALE)
        settle()
        receipts.values.firstOrNull { it.owner == owner }?.let { return it.value }
        if (!userConfirmed) return Rejected(Code.CONFIRMATION_REQUIRED)
        val previous = editor
        val source = candidates[owner] ?: return Rejected(Code.UNAVAILABLE)
        val id = uniqueId() ?: return Rejected(Code.INVALID)
        val nameId = newId().takeIf { HEX.matches(it) } ?: return Rejected(Code.INVALID)
        val document = PhoneSkillDraft.render(source, "phone-task-$nameId", true) as? PhoneSkillDraft.Ready
            ?: return Rejected(Code.UNAVAILABLE)
        if (previous != null && !cancel(previous)) return Rejected(Code.BUSY)
        return Editor(id, client, source, document, source.steps.indices.toList()).also { editor = it }.let(::shown)
    }

    /** Raw editing strings live only in this call, never in a field, permit, error or rendered document. */
    @Synchronized fun edit(client: Client, draftId: String, taskId: Long, revision: Long, edit: Edit): Reply {
        val e = matching(client, draftId, taskId) ?: return Rejected(Code.STALE)
        if (revision != e.revision) return Rejected(Code.STALE)
        if (e.write?.phase() in setOf(PhoneSkillWrite.Phase.STAGING, PhoneSkillWrite.Phase.COMMITTING)) return Rejected(Code.BUSY)
        settle()?.let { return it }
        if (e.retired) return Rejected(Code.STALE)
        if (edit.stepOrder.isEmpty() || edit.stepOrder.size > PhoneTaskTrace.MAX_STEPS ||
            edit.stepOrder.distinct().size != edit.stepOrder.size || edit.stepOrder.any { it !in e.source.steps.indices } ||
            edit.checkpoints.size != edit.stepOrder.size) return Rejected(Code.INVALID)
        val fields = listOf("goal" to edit.goal, "prerequisites" to edit.prerequisites) +
            edit.checkpoints.mapIndexed { index, value -> "checkpoints[$index]" to value }
        if (fields.any { it.second.length > MAX_FIELD } || fields.sumOf { it.second.length } > MAX_EDIT_BYTES - EDIT_OVERHEAD ||
            fields.sumOf { it.second.toByteArray(Charsets.UTF_8).size } > MAX_EDIT_BYTES - EDIT_OVERHEAD) {
            return Rejected(Code.TOO_LARGE)
        }
        val clean = fields.map { (key, value) -> key to Normalizer.normalize(value, Normalizer.Form.NFKC).trim() }
        if (clean.any { it.second.length > MAX_FIELD } ||
            clean.sumOf { it.second.toByteArray(Charsets.UTF_8).size } > MAX_EDIT_BYTES - EDIT_OVERHEAD) return Rejected(Code.TOO_LARGE)
        if (clean.any { SECRET.containsMatchIn(it.second) }) return Rejected(Code.SENSITIVE)
        if (e.revision == Long.MAX_VALUE) return Rejected(Code.STALE)
        val ordered = e.source.copy(steps = edit.stepOrder.map { e.source.steps[it] })
        val document = PhoneSkillDraft.render(ordered, e.document.skillName, true, userEdited = true) as? PhoneSkillDraft.Ready
            ?: return Rejected(Code.TOO_LARGE)
        e.document = document
        e.order = edit.stepOrder.toList()
        e.parameters = clean.filter { it.second.isNotEmpty() }.map { it.first }
        e.revision++ // Even identical sanitized text revokes the prior confirmation.
        e.write = null
        return shown(e)
    }

    @Synchronized fun view(client: Client, draftId: String, taskId: Long): Reply {
        if (!attached(client)) return Rejected(Code.STALE)
        receipts[draftId]?.takeIf { it.owner.taskId == taskId && it.client === client }?.let { return it.value }
        val e = matching(client, draftId, taskId) ?: return Rejected(Code.STALE)
        settle()?.let { return it }
        return shown(e)
    }

    @Synchronized fun beginSave(client: Client, draftId: String, taskId: Long, revision: Long, explicitConfirmed: Boolean): SaveReply {
        if (!attached(client)) return Rejected(Code.STALE)
        receipts[draftId]?.takeIf { it.owner.taskId == taskId && it.client === client }?.let { return it.value }
        val e = matching(client, draftId, taskId) ?: return Rejected(Code.STALE)
        if (revision != e.revision) return Rejected(Code.STALE)
        if (!explicitConfirmed) return Rejected(Code.CONFIRMATION_REQUIRED)
        val write = e.write
        if (write != null) {
            val result = write.result()
            if (result is PhoneSkillInstallResult.Saved) return settle()!!
            if (result is PhoneSkillInstallResult.Refused) return Rejected(code(result))
            return Existing(write)
        }
        return PhoneSkillWrite(e.document).also { e.write = it }.let(::Started)
    }

    /** Runtime already called write.finish; UI cannot provide or forge an install result. */
    @Synchronized fun saved(draftId: String, write: PhoneSkillWrite): Reply {
        val e = editor
        if (e == null || e.id != draftId || e.write !== write) {
            return receipts[draftId]?.takeIf { it.owner == write.document.owner && it.write.get() === write }?.value ?: Rejected(Code.STALE)
        }
        val result = write.result() ?: return Rejected(Code.BUSY)
        if (result is PhoneSkillInstallResult.Saved) return settle()!!
        if (e.retired) editor = null
        return Rejected(code(result as PhoneSkillInstallResult.Refused))
    }

    @Synchronized fun discard(client: Client, draftId: String, taskId: Long): Reply {
        if (!attached(client)) return Rejected(Code.STALE)
        receipts[draftId]?.takeIf { it.owner.taskId == taskId && it.client === client }?.let { return it.value }
        val e = matching(client, draftId, taskId) ?: return Rejected(Code.STALE)
        settle()?.let { return it }
        if (!cancel(e)) return Rejected(Code.CANNOT_CANCEL)
        editor = null
        return Discarded
    }

    @Synchronized fun retireClient(client: Client) {
        if (client.issuer !== issuer) return
        client.active = false
        val e = editor ?: return
        if (e.client === client) {
            settle()
            if (editor === e && cancel(e)) editor = null
        }
    }

    /** Old runtime candidates cannot be carried into another root. An already committing write remains observable. */
    @Synchronized fun onEngineRetired() {
        epoch++
        candidates.clear()
        val e = editor ?: return
        e.retired = true
        settle()
        if (editor === e && cancel(e)) editor = null
    }

    private fun attached(client: Client): Boolean = client.issuer === issuer && client.active
    private fun matching(client: Client, id: String, taskId: Long): Editor? {
        if (!attached(client)) return null
        return editor?.takeIf { it.client === client && it.id == id && it.source.owner.taskId == taskId }
    }
    private fun cancel(e: Editor): Boolean {
        val write = e.write ?: return true
        return when (write.phase()) {
            PhoneSkillWrite.Phase.STAGING -> write.cancel()
            PhoneSkillWrite.Phase.COMMITTING -> false
            PhoneSkillWrite.Phase.FINISHED -> write.result() !is PhoneSkillInstallResult.Saved
            PhoneSkillWrite.Phase.CANCELLED -> true
        }
    }
    private fun settle(): Saved? {
        val e = editor ?: return null
        val result = e.write?.result() as? PhoneSkillInstallResult.Saved ?: return null
        val saved = Saved(result.name, result.relativePath)
        receipts[e.id] = Receipt(e.source.owner, saved, e.client, WeakReference(e.write!!))
        while (receipts.size > MAX_CANDIDATES) receipts.remove(receipts.keys.first())
        candidates.remove(e.source.owner)
        editor = null
        return saved
    }
    private fun shown(e: Editor): Shown = Shown(View(e.id, e.source.owner, e.revision, e.document.skillName,
        e.document.markdown, e.order.toList(), e.parameters.toList(), e.write?.phase()))
    private fun uniqueId(): String? {
        val id = newId()
        return id.takeIf { HEX.matches(it) && it != editor?.id && it !in receipts }
    }
    private fun code(result: PhoneSkillInstallResult.Refused): Code = when (result) {
        PhoneSkillInstallResult.Refused.STALE -> Code.STALE
        PhoneSkillInstallResult.Refused.NO_HOME -> Code.NO_HOME
        PhoneSkillInstallResult.Refused.CONFLICT -> Code.CONFLICT
        PhoneSkillInstallResult.Refused.IO -> Code.IO
    }
    companion object {
        const val MAX_CANDIDATES = 8
        const val MAX_FIELD = 2000
        const val MAX_EDIT_BYTES = 32 * 1024
        private const val EDIT_OVERHEAD = 1024
        private val HEX = Regex("[a-f0-9]{32}")
        // Known markers only. Unknown names/values are still removed, never entrusted to a PII detector.
        private val SECRET = Regex("password|passwd|api[_ -]?key|access[_ -]?token|secret|密码|验证码|支付密码|cvv|安全码", RegexOption.IGNORE_CASE)
    }
}
