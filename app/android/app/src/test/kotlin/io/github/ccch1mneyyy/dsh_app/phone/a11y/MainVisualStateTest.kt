package io.github.ccch1mneyyy.dsh_app.phone.a11y

import org.junit.Assert.*
import org.junit.Test

class MainVisualStateTest {
    @Test fun sameWindowNewCandidatePreservesScopeButNeedsItsOwnFinalAcceptance() {
        val state = MainVisualState(Any())
        val scope = state.observed(11, "example.app")
        state.publish("s1"); state.candidate("s1")
        assertFalse(state.imageAccepted("s1"))
        state.accept("s1"); assertTrue(state.imageAccepted("s1"))
        assertSame(scope, state.observed(11, "example.app"))
        state.publish("s2"); state.candidate("s2")
        assertSame(scope, state.scope("s2")); assertNull(state.scope("s1"))
        assertFalse(state.imageAccepted("s2")); state.accept("s1")
        assertFalse(state.imageAccepted("s2"))
        state.accept("s2"); assertTrue(state.consume("s2")); assertFalse(state.consume("s2"))
    }

    @Test fun intermediateWindowOrUnknownCannotReviveEvenBeforeAnotherPublish() {
        val state = MainVisualState(Any())
        val first = state.observed(1, "example.app"); state.publish("s1")
        state.observed(2, "example.app")
        val returned = state.observed(1, "example.app")
        assertNotSame(first, returned); assertNull(state.scope("s1"))
        state.publish("s2"); assertSame(returned, state.scope("s2"))
        state.observed(null, null)
        assertNotSame(returned, state.observed(1, "example.app")); assertNull(state.scope("s2"))
    }

    @Test fun windowTransitionAfterTheScreenshotRetiresItsCoordinatesButKeepsTheScope() {
        val state = MainVisualState(Any())
        val scope = state.observed(1, "example.app"); state.publish("s1"); state.candidate("s1"); state.accept("s1")
        assertTrue(state.imageAccepted("s1"))
        // Away and back before any capture: nothing observed the other window, the image is still stale.
        state.windowChanged(); state.windowChanged()
        assertFalse(state.imageAccepted("s1")); assertFalse(state.consume("s1"))
        state.accept("s1"); assertFalse(state.imageAccepted("s1"))
        assertSame(scope, state.scope("s1"))
        state.publish("s2"); state.candidate("s2"); state.accept("s2"); assertTrue(state.consume("s2"))
    }

    @Test fun filteredCandidateAndTextOnlySnapshotsNeverAuthorizeAnyCoordinate() {
        val state = MainVisualState(Any())
        state.observed(1, "example.app"); state.publish("s1"); state.candidate("s1")
        // Real Core drops the image and therefore does not call acceptVisualObservation.
        assertFalse(state.consume("s1"))
        state.publish("s2"); state.accept("s2") // no actual candidate
        assertFalse(state.consume("s2"))
        // UNKNOWN may still receive one-shot human approval, but must first have a delivered image.
        state.observed(null, null); state.publish("s3"); state.candidate("s3")
        assertFalse(state.consume("s3")); state.accept("s3"); assertTrue(state.consume("s3"))
    }

    @Test fun abortAndConnectionEpochRejectLateAcceptanceAndOldWindow() {
        val epoch = Any(); val state = MainVisualState(epoch)
        val old = state.observed(1, "example.app"); state.publish("s1"); state.candidate("s1")
        state.invalidate(); state.accept("s1")
        assertNull(state.scope("s1")); assertFalse(state.imageAccepted("s1")); assertFalse(state.isCurrent(old, state.transitions()))
        assertNotEquals(old, MainVisualState(Any()).observed(1, "example.app"))
    }
}
