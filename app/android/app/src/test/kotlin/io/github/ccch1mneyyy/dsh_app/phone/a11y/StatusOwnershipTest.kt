package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks
import org.junit.Assert.*
import org.junit.Test

class StatusOwnershipTest {
    @Test fun replacementInvalidatesCleanupTicketButDoesNotKeepTheOldDisplayedStatus() {
        val tasks = PhoneTasks()
        val shown = StatusOwnership()
        val a = (tasks.begin() as PhoneTasks.Begin.Go).owner
        assertTrue(shown.publish { update -> tasks.runIfCurrent(a, update) })
        tasks.stop("stop A")
        val cleanupA = tasks.snapshot()
        tasks.clearStop()
        tasks.begin() // B can be a pure apps read: it need not publish a status.
        var oldCleanupApplied = false
        tasks.runIfInactive(cleanupA) { oldCleanupApplied = true }
        assertFalse(oldCleanupApplied)
        assertTrue(shown.takeStale())
        assertFalse(shown.takeStale())
    }

    @Test fun cleanupForOldTaskPreservesTheNewDisplayedStatus() {
        val tasks = PhoneTasks()
        val shown = StatusOwnership()
        val a = (tasks.begin() as PhoneTasks.Begin.Go).owner
        assertTrue(shown.publish { update -> tasks.runIfCurrent(a, update) })
        tasks.stop("stop A")
        tasks.clearStop()
        val b = (tasks.begin() as PhoneTasks.Begin.Go).owner
        assertTrue(shown.publish { update -> tasks.runIfCurrent(b, update) })
        assertFalse(shown.takeStale())
        assertFalse(shown.publish { update -> tasks.runIfCurrent(a, update) })
        assertFalse(shown.takeStale()) // A's rejected late status did not replace B's ownership.
    }

    @Test fun removingOnlyAStatusCanPreserveCurrentPromptHoldsAcrossPillRecreation() {
        val fold = FoldClock()
        fold.start(0)
        fold.hold(FoldClock.Hold.CONFIRM, 1)
        fold.reset()
        fold.hold(FoldClock.Hold.CONFIRM, 2) // Current card survives removal of the old pill.
        fold.start(3)
        assertTrue(fold.isHeld(FoldClock.Hold.CONFIRM))
        assertNull(fold.nextAt)
        assertFalse(fold.expand(4))
        fold.release(FoldClock.Hold.CONFIRM, 5)
        assertFalse(fold.held)
    }
}
