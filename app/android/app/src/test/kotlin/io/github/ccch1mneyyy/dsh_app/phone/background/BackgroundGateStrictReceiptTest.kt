package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundGateStrictReceiptTest {
    private val state = BackgroundGateState()
    private val expected = "original-owner"
    private fun accept(probe: BackgroundGateState.Probe, owner: Any? = expected, version: Any? = 1,
                       ok: Any? = true, display: Any? = true, inject: Any? = true,
                       error: Any? = null, injectError: Any? = null, detail: Any? = null) =
        state.updateStrict(probe, expected, owner, version, ok, display, inject, error, injectError, detail)

    @Test fun displayFactDoesNotComeFromOverallOkOrInventAnInputObservation() {
        val probe = state.begin { true }!!
        val notSent = accept(probe, ok = false, inject = null, error = "inputWindowNotReady")
            as BackgroundGateState.Update.Accepted
        assertTrue(notSent.receipt.trustedDisplayOk)
        assertNull(notSent.receipt.injectOk)
        assertEquals(BackgroundGateState.InjectFailure.WINDOW_NOT_READY, notSent.receipt.injectFailure)
        assertNull(state.snapshot.injectOk) // Never invent an attempted send just to retain its error.
        assertEquals("inputWindowNotReady", state.snapshot.injectError)
        val sent = accept(probe, ok = false, inject = false, error = "inputUnconfirmed")
            as BackgroundGateState.Update.Accepted
        assertTrue(sent.receipt.trustedDisplayOk)
        assertEquals(false, sent.receipt.injectOk)
        assertEquals(BackgroundGateState.InjectFailure.UNCONFIRMED, sent.receipt.injectFailure)
        val conflictingLabel = accept(probe, ok = false, inject = false, error = "inputWindowNotReady")
            as BackgroundGateState.Update.Accepted
        assertEquals(false, conflictingLabel.receipt.injectOk)
        assertEquals(BackgroundGateState.InjectFailure.UNCONFIRMED, conflictingLabel.receipt.injectFailure)
    }

    @Test fun exactOwnerVersionTypesAndTruthConjunctionAreRequired() {
        val probe = state.begin { true }!!
        val invalid = listOf(
            accept(probe, owner = "other"), accept(probe, version = 1L), accept(probe, ok = 1),
            accept(probe, display = "true"), accept(probe, inject = "true"),
            accept(probe, ok = false), accept(probe, display = false),
            accept(probe, error = "contradiction"), accept(probe, injectError = "contradiction"),
            accept(probe, ok = false, inject = false, error = 42),
        )
        invalid.forEach { assertSame(BackgroundGateState.Update.Invalid, it) }
        assertNull(state.snapshot.trustedDisplayOk)
    }

    @Test fun unknownRawErrorsAndDetailsAreNotForwardedToStatus() {
        val probe = state.begin { true }!!
        accept(probe, ok = false, inject = false, error = "PRIVATE_PACKAGE", injectError = "PRIVATE_BODY", detail = "PRIVATE_WINDOW")
        assertEquals("inputProbeFailed", state.snapshot.injectError)
        assertNull(state.snapshot.gateDetail)
    }

    @Test fun cancelledProbeCannotPublishButStillRequiresARealFreshProbeAfterCleanup() {
        var live = true
        val probe = state.begin { live }!!
        state.requireRetest()
        live = false
        state.cancelUnwantedPending()
        assertSame(BackgroundGateState.Update.Cancelled, accept(probe))
        assertFalse(state.completedWithCleanup(probe))
        val observed = state.snapshot
        state.connected(observed, Any())
        state.reset()
        assertTrue(state.needsRetest)
        val fresh = state.begin { true }!!
        assertTrue(accept(fresh) is BackgroundGateState.Update.Accepted)
        assertTrue(state.completedWithCleanup(fresh))
        assertFalse(state.needsRetest)
    }

    @Test fun aProbeRejectedBeforeAllocationReleasesTheRetestBarrier() {
        state.requireRetest()
        val probe = state.begin { true }!!
        assertTrue(state.needsRetest)
        assertTrue(state.concludedWithoutAllocation(probe))
        assertFalse(state.needsRetest)
        state.requireRetest()
        val stale = state.begin { true }!!
        val current = state.begin { true }!!
        assertFalse(state.concludedWithoutAllocation(stale))
        assertTrue(state.needsRetest)
        assertTrue(state.concludedWithoutAllocation(current))
        assertFalse(state.needsRetest)
    }

    @Test fun failedInputCheckCanFinishCleanupWithoutBecomingSuccessful() {
        state.requireRetest()
        val probe = state.begin { true }!!
        assertTrue(accept(probe, ok = false, inject = null, error = "inputWindowNotReady")
            is BackgroundGateState.Update.Accepted)
        assertTrue(state.needsRetest)
        assertTrue(state.completedWithCleanup(probe))
        assertFalse(state.needsRetest)
        assertEquals(true, state.snapshot.trustedDisplayOk)
        assertNull(state.snapshot.injectOk)
        assertEquals("inputWindowNotReady", state.snapshot.injectError)
    }

    @Test fun failedConnectionBeforeAllocationKeepsItsErrorButNotTheRetestBarrier() {
        state.requireRetest()
        val probe = state.begin { true }!!
        assertTrue(state.failed(probe, 42))
        assertTrue(state.concludedWithoutAllocation(probe))
        assertFalse(state.needsRetest)
        assertEquals(42, state.snapshot.connectionError)
        assertNull(state.snapshot.trustedDisplayOk)
        assertNull(state.snapshot.injectOk)
    }

    @Test fun failedAllocationCanFinishCleanupWithoutErasingItsError() {
        state.requireRetest()
        val probe = state.begin { true }!!
        assertTrue(state.failed(probe, 43, Any()))
        assertTrue(state.completedWithCleanup(probe))
        assertFalse(state.needsRetest)
        assertEquals(43, state.snapshot.connectionError)
    }

    @Test fun acceptedProbeDoesNotClearRetestUntilItsActualCleanupConsumerCompletes() {
        val old = state.begin { true }!!
        state.requireRetest()
        assertTrue(accept(old) is BackgroundGateState.Update.Accepted)
        assertTrue(state.needsRetest)
        val current = state.begin { true }!!
        assertFalse(state.completedWithCleanup(old))
        assertTrue(state.needsRetest)
        assertTrue(accept(current) is BackgroundGateState.Update.Accepted)
        assertTrue(state.completedWithCleanup(current))
    }
}
