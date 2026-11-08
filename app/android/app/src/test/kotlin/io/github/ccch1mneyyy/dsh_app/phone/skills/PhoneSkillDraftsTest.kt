package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.*
import io.github.ccch1mneyyy.dsh_app.runtime.PhoneSkillInstallResult
import io.github.ccch1mneyyy.dsh_app.runtime.PhoneSkillWrite
import org.junit.Assert.*
import org.junit.Test

class PhoneSkillDraftsTest {
    private fun candidate(id: Long = 1, count: Int = 2): PhoneTaskTrace.Snapshot {
        val owner = PhoneTasks.Owner(id, 1, true)
        val trace = PhoneTaskTrace(); trace.start(owner)
        repeat(count) {
            val action = if (it % 2 == 0) PhoneAction.Tap("s1", 1) else PhoneAction.Type("s1", 1, "PRIVATE_ORIGINAL")
            val target = TargetInfo("s1", 1, "按钮", "搜索", "private.app", "PRIVATE_APP", false, false, false)
            val ticket = trace.beginAction(owner, action, target)
            trace.finish(ticket, true, false, true)
        }
        trace.complete(owner, true)
        return trace.snapshot(owner)!!
    }
    private inner class Fixture {
        private var next = 0L
        val manager = PhoneSkillDrafts { (++next).toString(16).padStart(32, '0') }
        val client = manager.attachClient()
        val source = candidate()
        init { assertTrue(manager.offer(manager.currentEpoch(), source)) }
        fun open(client: PhoneSkillDrafts.Client = this.client) =
            (manager.open(client, source.owner, true) as PhoneSkillDrafts.Shown).view
        fun save(view: PhoneSkillDrafts.View, client: PhoneSkillDrafts.Client = this.client) =
            manager.beginSave(client, view.draftId, view.owner.taskId, view.revision, true)
    }
    private fun changes(order: List<Int> = listOf(0, 1), goal: String = "张三的待办") =
        PhoneSkillDrafts.Edit(goal, "北京市私人地址", order.map { "PRIVATE_CHECK_$it" }, order)
    private fun code(reply: Any) = (reply as PhoneSkillDrafts.Rejected).code

    @Test fun candidatesDoNotRenderUntilExplicitlyOpenedAndConfirmed() {
        val f = Fixture()
        assertEquals(1, f.manager.candidates().size)
        assertEquals(PhoneSkillDrafts.Code.CONFIRMATION_REQUIRED, code(f.manager.open(f.client, f.source.owner, false)))
        val view = f.open()
        assertEquals(1L, view.revision); assertNull(view.phase)
        assertFalse(view.markdown.contains("PRIVATE_"))
        assertEquals(PhoneSkillDrafts.Code.CONFIRMATION_REQUIRED,
            code(f.manager.beginSave(f.client, view.draftId, 1, 1, false)))
    }

    @Test fun editedFreeTextIsRemovedAndEveryNewPreviewRevokesOldConfirmation() {
        val f = Fixture(); val view = f.open()
        val edited = (f.manager.edit(f.client, view.draftId, 1, 1, changes(listOf(1, 0))) as PhoneSkillDrafts.Shown).view
        assertEquals(2L, edited.revision); assertEquals(listOf(1, 0), edited.stepOrder)
        assertTrue(edited.markdown.contains("用户重新整理"))
        assertFalse(edited.markdown.contains("张三")); assertFalse(edited.markdown.contains("私人地址"))
        assertFalse(edited.markdown.contains("PRIVATE_"))
        assertEquals(listOf("goal", "prerequisites", "checkpoints[0]", "checkpoints[1]"), edited.parameterizedFields)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(view)))
        val again = (f.manager.edit(f.client, view.draftId, 1, 2, changes(listOf(1, 0))) as PhoneSkillDrafts.Shown).view
        assertEquals(3L, again.revision); assertEquals(edited.markdown, again.markdown)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(edited)))
        assertTrue(f.save(again) is PhoneSkillDrafts.Started)
    }

    @Test fun secretMarkersAndBadOrOverlongEditsDoNotAlterTheAcceptedPreview() {
        val f = Fixture(); val view = f.open()
        for (edit in listOf(changes(goal = "password=PRIVATE_SECRET"), changes(goal = "验证码123456"))) {
            assertEquals(PhoneSkillDrafts.Code.SENSITIVE, code(f.manager.edit(f.client, view.draftId, 1, 1, edit)))
        }
        for (edit in listOf(changes(goal = "x".repeat(2001)), changes(goal = "\ufb03".repeat(1000)))) {
            assertEquals(PhoneSkillDrafts.Code.TOO_LARGE, code(f.manager.edit(f.client, view.draftId, 1, 1, edit)))
        }
        for (order in listOf(emptyList(), listOf(0, 0), listOf(-1), listOf(2))) {
            assertEquals(PhoneSkillDrafts.Code.INVALID, code(f.manager.edit(f.client, view.draftId, 1, 1, changes(order))))
        }
        assertEquals(view, (f.manager.view(f.client, view.draftId, 1) as PhoneSkillDrafts.Shown).view)
    }

    @Test fun utf8RequestBudgetIsMeasuredAfterNormalization() {
        val f = Fixture(); val source = candidate(2, 16); f.manager.offer(f.manager.currentEpoch(), source)
        val view = (f.manager.open(f.client, source.owner, true) as PhoneSkillDrafts.Shown).view
        // Fullwidth A shrinks to ASCII under NFKC: both raw-request and normalized byte limits matter.
        for (character in listOf("汉", "Ａ")) {
            val edit = PhoneSkillDrafts.Edit("目标", "前提", List(16) { character.repeat(1000) }, (0..15).toList())
            assertEquals(PhoneSkillDrafts.Code.TOO_LARGE, code(f.manager.edit(f.client, view.draftId, 2, 1, edit)))
        }
        assertEquals(1L, (f.manager.view(f.client, view.draftId, 2) as PhoneSkillDrafts.Shown).view.revision)
    }

    @Test fun duplicateSaveSharesTheOnlyPermitAndSuccessIsIdempotent() {
        val f = Fixture(); val view = f.open()
        val write = (f.save(view) as PhoneSkillDrafts.Started).write
        assertSame(write, (f.save(view) as PhoneSkillDrafts.Existing).write)
        assertTrue(write.beginCommit())
        assertEquals(PhoneSkillDrafts.Code.CANNOT_CANCEL, code(f.manager.discard(f.client, view.draftId, 1)))
        write.finish(PhoneSkillInstallResult.Saved(write.document.skillName))
        val saved = f.manager.saved(view.draftId, write) as PhoneSkillDrafts.Saved
        assertEquals("skills/${write.document.skillName}/SKILL.md", saved.relativePath)
        assertEquals(saved, f.save(view)); assertEquals(saved, f.manager.saved(view.draftId, write))
        assertTrue(f.manager.candidates().isEmpty())
    }

    @Test fun discardBeforeCommitRevokesTheRealPermitAndLateCallbackDoesNotAttachToANewDraft() {
        val f = Fixture(); val old = f.open()
        val write = (f.save(old) as PhoneSkillDrafts.Started).write
        assertSame(PhoneSkillDrafts.Discarded, f.manager.discard(f.client, old.draftId, 1))
        assertFalse(write.beginCommit())
        val current = f.open()
        write.finish(PhoneSkillInstallResult.Refused.STALE)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.saved(old.draftId, write)))
        assertEquals(current.draftId, (f.manager.view(f.client, current.draftId, 1) as PhoneSkillDrafts.Shown).view.draftId)
    }

    @Test fun failedWriteKeepsPreviewAndRequiresANewRevisionForRetry() {
        val f = Fixture(); val view = f.open()
        val write = (f.save(view) as PhoneSkillDrafts.Started).write
        write.finish(PhoneSkillInstallResult.Refused.IO)
        assertEquals(PhoneSkillDrafts.Code.IO, code(f.manager.saved(view.draftId, write)))
        assertEquals(PhoneSkillDrafts.Code.IO, code(f.save(view)))
        val edited = (f.manager.edit(f.client, view.draftId, 1, 1, changes()) as PhoneSkillDrafts.Shown).view
        assertEquals(2L, edited.revision)
        assertNotSame(write, (f.save(edited) as PhoneSkillDrafts.Started).write)
    }

    @Test fun retiredQueuedClientCanNeverOpenAndOldDetachCannotCancelReplacement() {
        val f = Fixture(); f.manager.retireClient(f.client)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.open(f.client, f.source.owner, true)))
        val fresh = f.manager.attachClient(); val view = f.open(fresh)
        f.manager.retireClient(f.client)
        assertTrue(f.manager.view(fresh, view.draftId, 1) is PhoneSkillDrafts.Shown)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.discard(f.client, view.draftId, 1)))
        val foreign = PhoneSkillDrafts().attachClient()
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.open(foreign, f.source.owner, true)))
    }

    @Test fun engineRetirementCancelsStagingButCannotRetractCommittingWrites() {
        for (commit in listOf(false, true)) {
            val f = Fixture(); val view = f.open(); val write = (f.save(view) as PhoneSkillDrafts.Started).write
            if (commit) assertTrue(write.beginCommit())
            f.manager.retireClient(f.client)
            val fresh = f.manager.attachClient()
            if (!commit) {
                assertFalse(write.beginCommit())
                assertTrue(f.manager.open(fresh, f.source.owner, true) is PhoneSkillDrafts.Shown)
            } else {
                assertEquals(PhoneSkillDrafts.Code.BUSY, code(f.manager.open(fresh, f.source.owner, true)))
                write.finish(PhoneSkillInstallResult.Saved(write.document.skillName))
                assertTrue(f.manager.saved(view.draftId, write) is PhoneSkillDrafts.Saved)
                assertTrue(f.manager.open(fresh, f.source.owner, true) is PhoneSkillDrafts.Saved)
                assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.view(f.client, view.draftId, 1)))
            }
        }
    }

    @Test fun anotherClientExplicitlyReplacesEditableOrStagingAndWrongWriteCannotFinishIt() {
        val f = Fixture(); val old = f.open(); val oldWrite = (f.save(old) as PhoneSkillDrafts.Started).write
        val fresh = f.manager.attachClient(); val current = f.open(fresh)
        assertFalse(oldWrite.beginCommit())
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.view(f.client, old.draftId, 1)))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.saved(current.draftId, oldWrite)))
        f.manager.retireClient(f.client)
        assertTrue(f.manager.view(fresh, current.draftId, 1) is PhoneSkillDrafts.Shown)
    }

    @Test fun reopeningSameTaskOnSameClientGivesNewIdentitySoOldDialogCleanupCannotCancelIt() {
        val f = Fixture(); val old = f.open(); val current = f.open()
        assertNotEquals(old.draftId, current.draftId)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.discard(f.client, old.draftId, 1)))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(old)))
        val edited = f.manager.edit(f.client, current.draftId, 1, current.revision, changes()) as PhoneSkillDrafts.Shown
        assertEquals(current.draftId, edited.view.draftId)
        assertEquals(current.revision + 1, edited.view.revision)
    }

    @Test fun candidateRetentionIsBoundedAndDoesNotReplaceTheOpenEditorsSource() {
        val f = Fixture(); val view = f.open()
        for (id in 2L..10L) assertTrue(f.manager.offer(f.manager.currentEpoch(), candidate(id)))
        assertEquals(8, f.manager.candidates().size)
        assertFalse(f.manager.candidates().any { it.owner.taskId == 1L })
        assertTrue(f.manager.view(f.client, view.draftId, 1) is PhoneSkillDrafts.Shown)
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.edit(f.client, view.draftId, 2, 1, changes())))
    }

    @Test fun engineExitClearsCandidatesAndCancelsQueuedWritesWithoutRetiringTheUiClient() {
        val f = Fixture(); val view = f.open(); val write = (f.save(view) as PhoneSkillDrafts.Started).write
        val oldEpoch = f.manager.currentEpoch()
        f.manager.onEngineRetired()
        assertTrue(f.manager.candidates().isEmpty()); assertFalse(write.beginCommit())
        assertFalse(f.manager.offer(oldEpoch, candidate(3)))
        assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.view(f.client, view.draftId, 1)))
        assertTrue(f.manager.offer(f.manager.currentEpoch(), candidate(2)))
        assertTrue(f.manager.open(f.client, candidate(2).owner, true) is PhoneSkillDrafts.Shown)
    }

    @Test fun engineExitDuringCommitPreservesSavedOutcomeButAFailedOldDraftCannotRetryOnNewRoot() {
        for (success in listOf(true, false)) {
            val f = Fixture(); val view = f.open(); val write = (f.save(view) as PhoneSkillDrafts.Started).write
            assertTrue(write.beginCommit()); f.manager.onEngineRetired()
            assertEquals(PhoneSkillDrafts.Code.CANNOT_CANCEL, code(f.manager.discard(f.client, view.draftId, 1)))
            write.finish(if (success) PhoneSkillInstallResult.Saved(write.document.skillName) else PhoneSkillInstallResult.Refused.IO)
            if (success) {
                assertTrue(f.manager.view(f.client, view.draftId, 1) is PhoneSkillDrafts.Saved)
                assertTrue(f.manager.saved(view.draftId, write) is PhoneSkillDrafts.Saved)
            } else {
                assertEquals(PhoneSkillDrafts.Code.STALE, code(f.manager.edit(f.client, view.draftId, 1, 1, changes())))
                assertEquals(PhoneSkillDrafts.Code.IO, code(f.manager.saved(view.draftId, write)))
                assertEquals(PhoneSkillDrafts.Code.STALE, code(f.save(view)))
            }
        }
    }
}
