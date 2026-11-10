package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

/** Exercises the exact parser invoked by all three real candidate publishers. */
class BackgroundChannelCapabilityTest {
    private fun probe() = mutableMapOf<String, Any?>(
        Proto.OK to true, Proto.RELEASE_RECEIPT to 1,
        Proto.OWNER_SCOPE_VERSION to 1, Proto.SCOPE_LIMIT to 3, Proto.TARGET_IDENTITY_VERSION to 1,
        Proto.RESOURCE_RECOVERY_VERSION to 1,
        Proto.RECOVERY_PEER to "10000000-0000-0000-0000-000000000001",
        Proto.RECOVERY_BOOT to "20000000-0000-0000-0000-000000000001",
        Proto.RECOVERY_PID to 42, Proto.RECOVERY_UID to 2000,
        Proto.RECOVERY_PID_NS_DEV to 7L, Proto.RECOVERY_PID_NS_INO to 9L,
    )

    @Test fun completeStrictPeerIsSerialUntilItsActualMuxHandshakeCompletes() {
        val cap = probe()
        assertEquals(1, backgroundRequestLimit(cap::get, cap::containsKey, false))
        assertEquals(3, backgroundRequestLimit(cap::get, cap::containsKey, true))
        // Features of other consumers are not invented prerequisites for ordinary BG tasks.
        assertFalse(cap.containsKey(Proto.PREVIEW_VERSION))
        assertFalse(cap.containsKey(Proto.VIEWPORT_VERSION))
    }

    @Test fun explicitNamespaceUnavailableAdmitsOrdinaryChannelWithoutClaimingRecoveryEvidence() {
        val cap = probe().apply {
            put(Proto.RECOVERY_PID_NS_AVAILABLE, false)
            put(Proto.RECOVERY_PID_NS_DEV, 0L); put(Proto.RECOVERY_PID_NS_INO, 0L)
        }
        assertEquals(1, backgroundRequestLimit(cap::get, cap::containsKey, false))
        assertEquals(3, backgroundRequestLimit(cap::get, cap::containsKey, true))
        for ((key, value) in listOf(
            Proto.RECOVERY_PID_NS_AVAILABLE to true, Proto.RECOVERY_PID_NS_AVAILABLE to null,
            Proto.RECOVERY_PID_NS_AVAILABLE to 0, Proto.RECOVERY_PID_NS_AVAILABLE to "false",
            Proto.RECOVERY_PID_NS_DEV to 7L, Proto.RECOVERY_PID_NS_INO to 9L,
        )) {
            val bad = cap + (key to value)
            assertEquals(0, backgroundRequestLimit(bad::get, bad::containsKey, true))
        }
        cap.remove(Proto.RECOVERY_PID_NS_AVAILABLE)
        assertEquals(0, backgroundRequestLimit(cap::get, cap::containsKey, true))
    }

    @Test fun transportCapacityCannotMakeAnOldOrIncompletePeerOperational() {
        for (key in probe().keys) {
            val cap = probe().apply { remove(key) }
            assertEquals(key, 0, backgroundRequestLimit(cap::get, cap::containsKey, false))
            assertEquals(key, 0, backgroundRequestLimit(cap::get, cap::containsKey, true))
        }
    }

    @Test fun capabilityTypesAndBirthUseTheExistingStrictDecoders() {
        for ((key, value) in listOf(
            Proto.OK to 1, Proto.RELEASE_RECEIPT to 1L, Proto.OWNER_SCOPE_VERSION to 1L,
            Proto.SCOPE_LIMIT to 2, Proto.TARGET_IDENTITY_VERSION to true,
            Proto.RESOURCE_RECOVERY_VERSION to 1L, Proto.RECOVERY_PID to 42L,
            Proto.RECOVERY_PEER to "unknown", Proto.RECOVERY_PID_NS_INO to 0L,
        )) {
            val cap = probe().apply { put(key, value) }
            assertEquals(key, 0, backgroundRequestLimit(cap::get, cap::containsKey, true))
        }
    }
}
