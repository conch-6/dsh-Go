package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundGateStateTest {
    @Test fun startsWithAllCapabilitiesUnknown() {
        val state = BackgroundGateState()

        assertEquals(
            BackgroundGateState.Snapshot(null, null, null, null),
            state.snapshot,
        )
    }

    @Test fun busyProbeLeavesUnknownCapabilitiesUntouched() {
        val state = BackgroundGateState()
        val before = state.snapshot

        assertFalse(state.update(state.begin { true }!!, false, "probeBusy", false, "busyInputError", "busyDetail"))

        assertEquals(
            BackgroundGateState.Snapshot(null, null, null, null),
            state.snapshot,
        )
        assertSame(before, state.snapshot)
    }

    @Test fun busyProbePreservesSuccessfulCapabilitiesAndDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, "trustedDisplayReady"))
        val before = state.snapshot

        assertFalse(state.update(state.begin { true }!!, false, "probeBusy", false, "busyInputError", "busyDetail"))

        assertEquals(
            BackgroundGateState.Snapshot(true, true, null, "trustedDisplayReady"),
            state.snapshot,
        )
        assertSame(before, state.snapshot)
    }

    @Test fun busyProbePreservesFailedCapabilitiesErrorAndDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "inputRejected", "failedDetail"))
        val before = state.snapshot

        assertFalse(state.update(state.begin { true }!!, true, "probeBusy", true, null, "busyDetail"))

        assertEquals(
            BackgroundGateState.Snapshot(false, false, "inputRejected", "failedDetail"),
            state.snapshot,
        )
        assertSame(before, state.snapshot)
    }

    @Test fun busyProbeDoesNotTurnUnknownInjectionIntoFailure() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, null, null, "displayOnly"))
        val before = state.snapshot

        assertFalse(state.update(state.begin { true }!!, false, "probeBusy", false, "busyInputError", null))

        assertEquals(
            BackgroundGateState.Snapshot(true, null, null, "displayOnly"),
            state.snapshot,
        )
        assertSame(before, state.snapshot)
    }

    @Test fun realDisplayFailureReplacesPreviouslySuccessfulCapabilities() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, "ready"))

        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", null, null, "displayDenied"))

        assertEquals(
            BackgroundGateState.Snapshot(false, null, null, "displayDenied"),
            state.snapshot,
        )
    }

    @Test fun realInjectionFailureUpdatesErrorWithoutLosingDisplaySuccess() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, "ready"))

        assertTrue(state.update(state.begin { true }!!, true, null, false, "inputRejected", "injectionDenied"))

        assertEquals(
            BackgroundGateState.Snapshot(true, false, "inputRejected", "injectionDenied"),
            state.snapshot,
        )
    }

    @Test fun subsequentFailureReplacesOldErrorAndDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "oldInputError", "oldDetail"))

        assertTrue(state.update(state.begin { true }!!, true, null, false, "newInputError", "newDetail"))

        assertEquals(
            BackgroundGateState.Snapshot(true, false, "newInputError", "newDetail"),
            state.snapshot,
        )
    }

    @Test fun successfulInjectionClearsOldErrorAndAbsentDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "oldInputError", "oldDetail"))

        assertTrue(state.update(state.begin { true }!!, true, null, true, "irrelevantInputError", null))

        assertEquals(
            BackgroundGateState.Snapshot(true, true, null, null),
            state.snapshot,
        )
    }

    @Test fun unknownInjectionAlsoClearsOldError() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, false, "oldInputError", "oldDetail"))

        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", null, "irrelevantInputError", "displayDenied"))

        assertEquals(
            BackgroundGateState.Snapshot(false, null, null, "displayDenied"),
            state.snapshot,
        )
    }

    @Test fun resetClearsFailedCapabilitiesErrorAndDetail() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "inputRejected", "failedDetail"))

        state.reset()

        assertEquals(
            BackgroundGateState.Snapshot(null, null, null, null),
            state.snapshot,
        )
    }

    @Test fun resetClearsSuccessfulCapabilitiesAndAllowsFreshResult() {
        val state = BackgroundGateState()
        assertTrue(state.update(state.begin { true }!!, true, null, true, null, "ready"))

        state.reset()

        assertEquals(
            BackgroundGateState.Snapshot(null, null, null, null),
            state.snapshot,
        )
        assertTrue(state.update(state.begin { true }!!, false, "displayRejected", false, "freshInputError", "freshDetail"))
        assertEquals(
            BackgroundGateState.Snapshot(false, false, "freshInputError", "freshDetail"),
            state.snapshot,
        )
    }
}
