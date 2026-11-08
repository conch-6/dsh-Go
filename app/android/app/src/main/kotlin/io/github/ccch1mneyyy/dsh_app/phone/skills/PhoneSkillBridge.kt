package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.runtime.PhoneSkillInstallResult
import io.github.ccch1mneyyy.dsh_app.runtime.PhoneSkillWrite
import java.util.Locale

/** Local MethodChannel adapter. Invoke on a worker: parsing/rendering never runs on the UI thread. */
internal class PhoneSkillBridge(
    private val drafts: PhoneSkillDrafts,
    private val save: (PhoneSkillWrite, (PhoneSkillInstallResult) -> Unit) -> Unit,
    private val changed: () -> Unit,
) {
    fun call(client: PhoneSkillDrafts.Client, method: String, arguments: Any?): Map<String, Any?> {
        val a = arguments as? Map<*, *> ?: return rejected("invalid")
        val task = positive(a["taskId"]) ?: return rejected("invalid")
        return when (method) {
            "skillDraft" -> when (a["action"] ?: "open") {
                "open" -> {
                    if (!keys(a, "action", "taskId", "generation", "confirmed")) return rejected("invalid")
                    val generation = positive(a["generation"]) ?: return rejected("invalid")
                    reply(drafts.open(client, PhoneTaskTrace.OwnerKey(task, generation), a["confirmed"] == true))
                }
                "view" -> {
                    if (!keys(a, "action", "taskId", "draftId")) return rejected("invalid")
                    val id = id(a) ?: return rejected("invalid")
                    reply(drafts.view(client, id, task))
                }
                "edit" -> {
                    if (!keys(a, "action", "taskId", "draftId", "revision", "goal", "prerequisites", "checkpoints", "stepOrder")) return rejected("invalid")
                    val id = id(a) ?: return rejected("invalid")
                    val revision = positive(a["revision"]) ?: return rejected("invalid")
                    val goal = a["goal"] as? String ?: return rejected("invalid")
                    val prerequisites = a["prerequisites"] as? String ?: return rejected("invalid")
                    val checkpoints = a["checkpoints"] as? List<*> ?: return rejected("invalid")
                    val order = a["stepOrder"] as? List<*> ?: return rejected("invalid")
                    if (checkpoints.size > PhoneTaskTrace.MAX_STEPS || order.size > PhoneTaskTrace.MAX_STEPS) return rejected("too_large")
                    if (checkpoints.any { it !is String } || order.any { integer(it) == null }) return rejected("invalid")
                    val positions = order.map { integer(it)!! }
                    if (positions.any { it !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }) return rejected("invalid")
                    reply(drafts.edit(client, id, task, revision, PhoneSkillDrafts.Edit(goal, prerequisites,
                        checkpoints.map { it as String }, positions.map { it.toInt() })))
                }
                else -> rejected("invalid")
            }
            "saveSkillDraft" -> {
                if (!keys(a, "taskId", "draftId", "revision", "confirmed")) return rejected("invalid")
                val id = id(a) ?: return rejected("invalid")
                val revision = positive(a["revision"]) ?: return rejected("invalid")
                when (val begun = drafts.beginSave(client, id, task, revision, a["confirmed"] == true)) {
                    is PhoneSkillDrafts.Started -> {
                        // beginSave released the manager monitor. Runtime owns the only commit permit.
                        save(begun.write) {
                            drafts.saved(id, begun.write)
                            changed()
                        }
                        writeState(id, begun.write)
                    }
                    is PhoneSkillDrafts.Existing -> writeState(id, begun.write)
                    is PhoneSkillDrafts.Rejected -> rejected(begun.code.name.lowercase(Locale.ROOT))
                    is PhoneSkillDrafts.Saved -> saved(begun)
                }
            }
            "discardSkillDraft" -> {
                if (!keys(a, "taskId", "draftId")) return rejected("invalid")
                val id = id(a) ?: return rejected("invalid")
                reply(drafts.discard(client, id, task))
            }
            else -> rejected("invalid")
        }
    }

    private fun writeState(id: String, write: PhoneSkillWrite): Map<String, Any?> {
        // A real callback/result may already have won, including synchronous Runtime refusal.
        if (write.result() != null) return reply(drafts.saved(id, write))
        return when (write.phase()) {
            PhoneSkillWrite.Phase.STAGING -> mapOf("kind" to "saving", "phase" to "staging")
            PhoneSkillWrite.Phase.COMMITTING -> mapOf("kind" to "saving", "phase" to "committing")
            PhoneSkillWrite.Phase.CANCELLED -> rejected("stale")
            PhoneSkillWrite.Phase.FINISHED -> reply(drafts.saved(id, write))
        }
    }

    private fun reply(value: PhoneSkillDrafts.Reply): Map<String, Any?> = when (value) {
        is PhoneSkillDrafts.Shown -> value.view.let { v -> mapOf("kind" to "shown", "draft" to linkedMapOf(
            "draftId" to v.draftId, "taskId" to v.owner.taskId, "generation" to v.owner.lifecycle,
            "revision" to v.revision, "skillName" to v.skillName, "markdown" to v.markdown,
            "stepOrder" to v.stepOrder, "parameterizedFields" to v.parameterizedFields,
            "phase" to v.phase?.name?.lowercase(Locale.ROOT))) }
        is PhoneSkillDrafts.Saved -> saved(value)
        is PhoneSkillDrafts.Rejected -> rejected(value.code.name.lowercase(Locale.ROOT))
        PhoneSkillDrafts.Discarded -> mapOf("kind" to "discarded")
    }
    private fun saved(value: PhoneSkillDrafts.Saved): Map<String, Any?> =
        mapOf("kind" to "saved", "name" to value.name, "relativePath" to value.relativePath)
    private fun id(a: Map<*, *>): String? = (a["draftId"] as? String)?.takeIf { ID.matches(it) }
    private fun keys(a: Map<*, *>, vararg allowed: String): Boolean = a.keys.all { it in allowed }
    private fun positive(value: Any?): Long? = integer(value)?.takeIf { it > 0 }
    private fun integer(value: Any?): Long? = when (value) { is Int -> value.toLong(); is Long -> value; else -> null }
    companion object {
        private val ID = Regex("[a-f0-9]{32}")
        fun rejected(code: String): Map<String, Any?> = mapOf("kind" to "rejected", "code" to code)
    }
}
