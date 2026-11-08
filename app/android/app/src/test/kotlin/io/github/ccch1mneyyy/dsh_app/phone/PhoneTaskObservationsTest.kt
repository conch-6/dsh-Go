package io.github.ccch1mneyyy.dsh_app.phone

import io.github.ccch1mneyyy.dsh_app.phone.a11y.MainScreenDriver
import org.junit.Assert.*
import org.junit.Test

class PhoneTaskObservationsTest {
    private class Driver : PhoneDriver {
        override val screen = PhoneScreen.MAIN
        var actions = 0
        var capturedAdmission: ((() -> Boolean) -> Boolean)? = null
        var capturedAllowed: (() -> Boolean)? = null
        var scope: VisualScope? = null
        val imageCommits = mutableListOf<String>()
        override fun acceptVisualObservation(screenId: String) { imageCommits += screenId }
        val opens = mutableListOf<PhoneAppIdentity>()
        var duringOpen: () -> Unit = {}
        var collectGate: (() -> Boolean)? = null
        var duringCollect: () -> Unit = {}
        var collected = CollectResult(emptyList(), 0, "done", null)
        override fun visualScope(screenId: String): VisualScope? = scope.takeIf { screenId == "s1" }
        override fun availability() = Availability(true)
        override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("s1", "screen", "App", "app")
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId, "button", "send", "app", "App", false, false, false)
        override fun perform(action: PhoneAction): ActionResult { actions++; return ActionResult(true, "done") }
        override fun perform(action: PhoneAction, allowed: () -> Boolean,
                             coordinateAdmission: ((() -> Boolean) -> Boolean)?): ActionResult {
            capturedAdmission = coordinateAdmission
            capturedAllowed = allowed
            return if (allowed()) perform(action) else ActionResult(false, "stopped")
        }
        override fun open(target: PhoneAppIdentity): ActionResult {
            opens += target
            duringOpen()
            return ActionResult(true, "opened", ScreenSnapshot("sOpen", "opened screen", "App", target.packageName))
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = collected
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?, allowed: () -> Boolean): CollectResult {
            collectGate = allowed
            duringCollect()
            return collected
        }
        override fun foregroundPackage() = "app"
    }
    private fun owner(tasks: PhoneTasks) = (tasks.begin() as PhoneTasks.Begin.Go).owner

    @Test fun boundOpenPassesTheOriginalNativeIdentityAndRecordsOnlyItsReturnedScreen() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        val identity = PhoneAppIdentity("example.app", 1010123)
        val result = bound.open(identity)
        assertTrue(result.ok)
        assertSame(identity, physical.opens.single())
        assertNotNull(bound.target("sOpen", 1))
    }

    @Test fun staleBoundOpenCannotDispatchOrPublishIntoTheReplacementScope() {
        val tasks = PhoneTasks(); val physical = Driver(); val ledger = PhoneTaskObservations(tasks)
        val bound = ledger.bind(physical, owner(tasks))
        val identity = PhoneAppIdentity("example.app", 10123)
        physical.duringOpen = { tasks.stop("replaced"); tasks.clearStop(); tasks.begin() }
        assertThrows(InterruptedException::class.java) { bound.open(identity) }
        assertEquals(1, physical.opens.size)
        val replacement = ledger.bind(physical, checkNotNull(tasks.activeOwner()))
        assertNull(replacement.target("sOpen", 1))
        assertThrows(InterruptedException::class.java) { bound.open(identity) }
        assertEquals(1, physical.opens.size) // Rejected before calling the physical driver again.
    }

    @Test fun collectionPassesItsOwnLivePauseGateInsteadOfTheDisplayedTasksState() {
        val a = PhoneTasks(); val b = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(a).bind(physical, owner(a))
        owner(b); b.setPaused(true)
        bound.observe(false, false)
        bound.collect("s1", 1, 3, null)
        val allowed = checkNotNull(physical.collectGate)
        assertTrue(allowed()) // Pausing another task must not stop this collection.
        a.setPaused(true); assertFalse(allowed())
        b.setPaused(false); assertFalse(allowed())
        a.setPaused(false); assertTrue(allowed())
        a.stop("user"); a.clearStop(); a.begin()
        assertFalse(allowed()) // Resume/new scope cannot revive the old loop's permission.
    }

    @Test fun collectionFinishingAfterItsScopeWasReplacedCannotPublishAnObservation() {
        val tasks = PhoneTasks(); val ledger = PhoneTaskObservations(tasks); val physical = Driver()
        val bound = ledger.bind(physical, owner(tasks))
        bound.observe(false, false)
        physical.collected = CollectResult(listOf("synthetic"), 1, "done", ScreenSnapshot("sLate", "screen", "App", "app"))
        physical.duringCollect = { tasks.stop("user"); tasks.clearStop(); tasks.begin() }
        assertThrows(InterruptedException::class.java) { bound.collect("s1", 1, 3, null) }
        val fresh = ledger.bind(physical, checkNotNull(tasks.activeOwner()))
        assertNull(fresh.target("sLate", 1))
        assertFalse(checkNotNull(physical.collectGate)())
    }

    @Test fun anotherSessionCannotUseAnIdItNeverObservedEvenOnTheSamePhysicalDriver() {
        val physical = Driver()
        val a = PhoneTasks(); val b = PhoneTasks()
        val first = PhoneTaskObservations(a).bind(physical, owner(a))
        val second = PhoneTaskObservations(b).bind(physical, owner(b))
        first.observe(false, false)
        assertNull(second.target("s1", 1))
        assertFalse(second.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(0, physical.actions)
        assertTrue(first.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(1, physical.actions)
    }

    @Test fun replacementDriverWithTheSameCounterDoesNotInheritAnOldObservation() {
        val tasks = PhoneTasks(); val ledger = PhoneTaskObservations(tasks); val owner = owner(tasks)
        ledger.bind(Driver(), owner).observe(false, false)
        val replacement = Driver(); val bound = ledger.bind(replacement, owner)
        assertNull(bound.target("s1", 1))
        assertFalse(bound.perform(PhoneAction.Tap("s1", 1)).ok)
        assertEquals(0, replacement.actions)
        bound.observe(false, false)
        assertTrue(bound.perform(PhoneAction.Tap("s1", 1)).ok)
    }

    @Test fun stopAndExplicitResumeCannotReviveTheOldBoundDriver() {
        val tasks = PhoneTasks(); val physical = Driver()
        val bound = PhoneTaskObservations(tasks).bind(physical, owner(tasks))
        bound.observe(false, false)
        tasks.stop("user"); tasks.clearStop(); tasks.begin()
        try { bound.perform(PhoneAction.Tap("s1", 1)); fail("old lifetime dispatched") } catch (_: InterruptedException) { }
        assertEquals(0, physical.actions)
    }
    @Test fun visualCommitRequiresThisOwnerAndTheSameObservedDriver() {
        val a = PhoneTasks(); val b = PhoneTasks(); val physical = Driver()
        val ledger = PhoneTaskObservations(a)
        val bound = ledger.bind(physical, owner(a))
        bound.observe(false, true)
        PhoneTaskObservations(b).bind(physical, owner(b)).acceptVisualObservation("s1")
        assertTrue(physical.imageCommits.isEmpty())
        val replacement = Driver()
        ledger.bind(replacement, checkNotNull(a.activeOwner())).acceptVisualObservation("s1")
        assertTrue(replacement.imageCommits.isEmpty())
        bound.acceptVisualObservation("s1")
        assertEquals(listOf("s1"), physical.imageCommits)
        a.stop("stop"); a.clearStop(); a.begin()
        assertThrows(InterruptedException::class.java) { bound.acceptVisualObservation("s1") }
        assertEquals(1, physical.imageCommits.size)
    }

    @Test fun actualWrapperCoordinateClaimCannotUseARetiredOrPausedOwner() {
        val tasks = PhoneTasks(); val physical = Driver()
        val owner = owner(tasks); val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        bound.observe(false, false); bound.perform(PhoneAction.TapXY("s1", 1, 1))
        val admission = checkNotNull(physical.capturedAdmission)
        var claims = 0
        assertTrue(admission { claims++; true })
        tasks.setPaused(true)
        assertFalse(admission { claims++; true })
        tasks.setPaused(false); tasks.stop("stop"); tasks.clearStop(); tasks.begin()
        assertFalse(admission { claims++; true }); assertEquals(1, claims)
    }
    @Test fun pauseWhileTheMainDriverResolvesATargetRefusesItsPhysicalDispatch() {
        val tasks = PhoneTasks(); val physical = Driver(); val owner = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        bound.observe(false, false); bound.perform(PhoneAction.Tap("s1", 1))
        val allowed = checkNotNull(physical.capturedAllowed)
        assertNull(MainScreenDriver.refuseHalted(allowed)) // Admitted before resolve() captures.
        assertTrue(tasks.setPausedIfCurrent(owner, true)) // The person pauses during that capture.
        val refused = checkNotNull(MainScreenDriver.refuseHalted(allowed))
        assertFalse(refused.ok); assertNull(refused.screen)
        assertTrue(tasks.setPausedIfCurrent(owner, false)); assertNull(MainScreenDriver.refuseHalted(allowed))
        tasks.stop("user"); tasks.clearStop(); tasks.begin()
        assertNotNull(MainScreenDriver.refuseHalted(allowed)) // A new lifetime cannot admit the old dispatch.
    }

    @Test fun actualLedgerRevokesScopeOnTextOnlyObservationBeforeAComesBack() {
        val tasks = PhoneTasks(); val physical = Driver(); val owner = owner(tasks)
        val bound = PhoneTaskObservations(tasks).bind(physical, owner)
        val a = VisualScope.Main(Any(), Any(), 1, "app")
        physical.scope = a; bound.observe(false, false)
        assertTrue(tasks.confirmVisualIfCurrent(owner, a))
        physical.scope = null; bound.observe(false, false)
        assertFalse(tasks.confirmVisualIfCurrent(owner, a))
        physical.scope = a; bound.observe(false, false)
        assertFalse(tasks.hasVisualGrant(owner, a))
    }

}
