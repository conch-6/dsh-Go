package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

/** Actual Host admission table; this tests ownership/drain, not Android physical cleanup. */
class OwnerScopeRetirementTest {
    private fun enter(table: OwnerScopes<Any, String>, owner: String): OwnerScopes.Record<Any> =
        (table.enter(owner, true, false, false) { Any() } as OwnerScopes.Entry.Acquired<Any, String>).record

    @Test fun retirementSealsBeforeBusyBodyReturnsAndRetainsItsOriginalCore() {
        val table = OwnerScopes<Any, String>()
        val original = enter(table, "A")
        assertNull(table.beginRetire())
        var constructed = false
        val late = table.enter("B", true, false, false) { constructed = true; Any() }
            as OwnerScopes.Entry.Refused<Any, String>
        assertEquals("peerRetired", late.code)
        assertFalse(constructed)
        table.leave(original)
        val captured = checkNotNull(table.beginRetire())
        assertEquals(1, captured.size)
        assertSame(original, captured.single())
        assertSame(original.core, captured.single().core)
        table.finishRetire(false)
    }

    @Test fun cleanupFailureKeepsEveryOriginalForAnExactRetry() {
        val table = OwnerScopes<Any, String>()
        val a = enter(table, "A"); table.leave(a)
        val b = enter(table, "B"); table.leave(b)
        val first = checkNotNull(table.beginRetire())
        assertEquals(listOf(a, b), first)
        // The real Host reports false if any captured Core/window/preview is not closed.
        table.finishRetire(false)
        val again = checkNotNull(table.beginRetire())
        assertSame(a, again[0]); assertSame(b, again[1])
        assertSame(a.core, again[0].core); assertSame(b.core, again[1].core)
        table.finishRetire(true)
        assertEquals("peerRetired", table.enterGlobal())
        var allocated = false
        assertTrue(table.enter("C", true, false, false) { allocated = true; Any() } is OwnerScopes.Entry.Refused)
        assertFalse(allocated)
    }

    @Test fun originalLegacyGlobalBodyMustLeaveBeforeWholePeerCleanupCanClaim() {
        val table = OwnerScopes<Any, String>()
        assertNull(table.enterGlobal(legacyResource = true))
        assertNull(table.beginRetire())
        assertEquals("peerRetired", table.enterGlobal(legacyResource = true))
        table.leaveGlobal()
        assertTrue(checkNotNull(table.beginRetire()).isEmpty())
        table.finishRetire(true)
        assertEquals("peerRetired", table.enterGlobal())
    }

    @Test fun retirementDoesNotSynthesizeANormalReleaseReceipt() {
        val table = OwnerScopes<Any, String>()
        val original = enter(table, "A"); table.leave(original)
        assertSame(original, checkNotNull(table.beginRetire()).single())
        table.finishRetire(false)
        val refused = table.enter("A", false, false, true) { error("no new core") }
            as OwnerScopes.Entry.Refused<Any, String>
        assertEquals("peerRetired", refused.code)
        assertFalse(refused.unknown)
        assertSame(original, checkNotNull(table.beginRetire()).single())
        table.finishRetire(true)
    }

    @Test fun oldCompletedReceiptDoesNotPermitRecreationAfterRetirement() {
        val table = OwnerScopes<Any, String>()
        val original = enter(table, "A"); table.leave(original)
        val release = table.enter("A", false, false, true) { error("original only") }
            as OwnerScopes.Entry.Acquired<Any, String>
        table.leave(release.record, "original physical receipt")
        assertTrue(checkNotNull(table.beginRetire()).isEmpty())
        table.finishRetire(true)
        var created = false
        val late = table.enter("A", true, false, false) { created = true; Any() }
            as OwnerScopes.Entry.Refused<Any, String>
        assertEquals("peerRetired", late.code)
        assertFalse(created)
        assertFalse(late.unknown)
    }

    @Test fun releasedCoreLeavesOnlyBoundedKnownOwnerIdentityNotANeverAdmittedClaim() {
        val table = OwnerScopes<Any, String>(limit = 1, lifetime = 1)
        val original = enter(table, "A"); table.leave(original)
        assertSame(original, checkNotNull(table.beginRetire()).single())
        table.finishRetire(true)
        val known = table.enter("A", true, false, false) { error("retired") }
            as OwnerScopes.Entry.Refused<Any, String>
        val unseen = table.enter("B", true, false, false) { error("retired") }
            as OwnerScopes.Entry.Refused<Any, String>
        assertEquals("peerRetired", known.code)
        assertFalse(known.unknown)
        assertTrue(unseen.unknown)
        assertTrue(checkNotNull(table.beginRetire()).isEmpty())
        table.finishRetire(true)
    }
}
