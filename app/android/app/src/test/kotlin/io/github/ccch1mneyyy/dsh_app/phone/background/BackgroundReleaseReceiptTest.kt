package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundReleaseReceiptTest {
    @Test fun oldOrMalformedPeerRepliesCannotReleaseTheOriginalOwnersLease() {
        fun accepts(version: Any? = 1, owner: Any? = "owner-A", ok: Any? = true,
            released: Any? = true, empty: Any? = true) =
            BackgroundReleaseReceipt.accepts("owner-A", version, owner, ok, released, empty)
        assertTrue(accepts())
        for (version in listOf(null, 0, 1L, 1.0, "1", true)) assertFalse(accepts(version = version))
        for (owner in listOf(null, "owner-B", "", 1)) assertFalse(accepts(owner = owner))
        for (falseOrMalformed in listOf(null, false, 1, "true")) {
            assertFalse(accepts(ok = falseOrMalformed))
            assertFalse(accepts(released = falseOrMalformed))
            assertFalse(accepts(empty = falseOrMalformed))
        }
        // A release API ACK alone is weaker than the subsequent ATMS full-task barrier.
        assertFalse(accepts(empty = false))
    }

    @Test fun neverCreatedIsAnExclusiveRegisteredScopeReceiptNotAnEmptyIdShortcut() {
        fun accepts(released: Any? = null, empty: Any? = null, never: Any? = true) =
            BackgroundReleaseReceipt.accepts("owner-A", 1, "owner-A", true, released, empty, never)
        assertTrue(accepts())
        assertFalse(accepts(released = true, empty = true))
        assertFalse(accepts(released = false))
        for (bad in listOf(null, false, 1, "true")) assertFalse(accepts(never = bad))
        assertFalse(BackgroundReleaseReceipt.accepts("owner-A", 1, "unknown", true, null, null, true))
    }

    @Test fun displayOwnersAreOpaqueUniqueLifetimesAndNeverContainSessionMetadata() {
        fun display() = BackgroundDisplay(
            channelProvider = { error("constructing an owner must not open a channel") },
            journal = BackgroundResourceJournal({ null }, { error("unused owner must not write a resource record") })
                .apply { assertTrue(load()) },
            mayUse = { error("unused owner must not request admission") },
            admitUse = { error("unused owner must not admit an action") },
        )
        val a = display()
        val b = display()
        assertNotEquals(a.ownerToken, b.ownerToken)
        assertEquals(java.util.UUID.fromString(a.ownerToken).toString(), a.ownerToken)
        assertEquals(java.util.UUID.fromString(b.ownerToken).toString(), b.ownerToken)
        assertTrue(a.release()) // no launch was dispatched, so no platform resource needs claiming
    }
}
