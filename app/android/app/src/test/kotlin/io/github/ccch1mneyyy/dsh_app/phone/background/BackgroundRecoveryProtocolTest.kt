package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

/** The production parsers take the same getters as actual Bundle callers; no Android stand-ins. */
class BackgroundRecoveryProtocolTest {
    private val peer = "10000000-0000-0000-0000-000000000001"
    private val boot = "20000000-0000-0000-0000-000000000001"
    private val owner = "30000000-0000-0000-0000-000000000001"
    private val birth = BackgroundResourceJournal.Birth(peer, boot, 42, 2000, 7L, 9L)
    private fun record(id: Int?) = BackgroundResourceJournal.Record(
        owner, "40000000-0000-0000-0000-000000000001", "probe", birth, null, id)

    @Test fun birthRequiresExactNativeTypesAndCompleteNamespaceIdentity() {
        val cap = mutableMapOf<String, Any?>(
            Proto.RESOURCE_RECOVERY_VERSION to 1, Proto.RECOVERY_PEER to peer,
            Proto.RECOVERY_BOOT to boot, Proto.RECOVERY_PID to 42, Proto.RECOVERY_UID to 2000,
            Proto.RECOVERY_PID_NS_DEV to 7L, Proto.RECOVERY_PID_NS_INO to 9L)
        assertEquals(birth, BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey))
        cap[Proto.RECOVERY_PID] = 42L
        assertNull(BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey))
        cap[Proto.RECOVERY_PID] = 42; cap.remove(Proto.RECOVERY_PID_NS_INO)
        assertNull(BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey))
    }

    @Test fun namespaceUnavailableRequiresExplicitBooleanAndExactZeroSentinels() {
        val cap = mutableMapOf<String, Any?>(
            Proto.RESOURCE_RECOVERY_VERSION to 1, Proto.RECOVERY_PEER to peer,
            Proto.RECOVERY_BOOT to boot, Proto.RECOVERY_PID to 42, Proto.RECOVERY_UID to 2000,
            Proto.RECOVERY_PID_NS_DEV to 0L, Proto.RECOVERY_PID_NS_INO to 0L,
            Proto.RECOVERY_PID_NS_AVAILABLE to false)
        assertEquals(birth.copy(pidNsDev = 0L, pidNsIno = 0L, pidNsAvailable = false),
            BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey))
        for ((key, value) in listOf(
            Proto.RECOVERY_PID_NS_AVAILABLE to true, Proto.RECOVERY_PID_NS_AVAILABLE to null,
            Proto.RECOVERY_PID_NS_AVAILABLE to 0, Proto.RECOVERY_PID_NS_AVAILABLE to "false",
            Proto.RECOVERY_PID_NS_DEV to 7L, Proto.RECOVERY_PID_NS_INO to 9L,
            Proto.RECOVERY_PID_NS_DEV to 0, Proto.RECOVERY_PID_NS_INO to 0,
        )) {
            val bad = cap + (key to value)
            assertNull(BackgroundRecoveryProtocol.birth(bad::get, bad::containsKey))
        }
        cap.remove(Proto.RECOVERY_PID_NS_AVAILABLE)
        assertNull(BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey))
        cap[Proto.RECOVERY_PID_NS_DEV] = 7L; cap[Proto.RECOVERY_PID_NS_INO] = 9L
        cap[Proto.RECOVERY_PID_NS_AVAILABLE] = true
        assertEquals(birth, BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey))
        cap[Proto.RECOVERY_PID_NS_AVAILABLE] = null
        assertNull(BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey))
    }

    @Test fun unavailableNamespaceCannotConsumeDeadPeerEmptyButCanUseIndependentProofs() {
        val unavailable = record(11).copy(birth = birth.copy(pidNsDev = 0L, pidNsIno = 0L, pidNsAvailable = false))
        val receipt = mutableMapOf<String, Any?>(Proto.OK to true,
            Proto.RESOURCE_RECOVERY_VERSION to 1, Proto.RECOVERY_PEER to peer,
            Proto.OWNER to owner, Proto.RECOVERY_KIND to "deadPeerEmpty", Proto.DISPLAY_ID to 11)
        assertFalse(BackgroundRecoveryProtocol.recovered(unavailable, receipt::get, receipt::containsKey))
        receipt[Proto.RECOVERY_KIND] = "previousBoot"
        assertTrue(BackgroundRecoveryProtocol.recovered(unavailable, receipt::get, receipt::containsKey))
        receipt[Proto.RECOVERY_KIND] = "peerRetired"
        assertTrue(BackgroundRecoveryProtocol.retired(peer, receipt::get))
    }

    @Test fun allocationConsumesTheAlreadyStrippedBodyAndNeverTreatsPinAsAnId() {
        val body = mutableMapOf<String, Any?>(Proto.OK to true,
            Proto.RESOURCE_RECOVERY_VERSION to 1, Proto.DISPLAY_ID to 11)
        assertEquals(11, BackgroundRecoveryProtocol.allocationId(body::get))
        body[Proto.DISPLAY_ID] = 11L
        assertNull(BackgroundRecoveryProtocol.allocationId(body::get))
        body[Proto.DISPLAY_ID] = 0
        assertNull(BackgroundRecoveryProtocol.allocationId(body::get))
        body[Proto.DISPLAY_ID] = 11; body[Proto.OK] = 1
        assertNull(BackgroundRecoveryProtocol.allocationId(body::get))
    }

    @Test fun recoveryProofMustMatchOriginalPeerOwnerAndActualIdPresence() {
        val receipt = mutableMapOf<String, Any?>(Proto.OK to true,
            Proto.RESOURCE_RECOVERY_VERSION to 1, Proto.RECOVERY_PEER to peer,
            Proto.OWNER to owner, Proto.RECOVERY_KIND to "deadPeerEmpty", Proto.DISPLAY_ID to 11)
        assertTrue(BackgroundRecoveryProtocol.recovered(record(11), receipt::get, receipt::containsKey))
        receipt[Proto.DISPLAY_ID] = 12
        assertFalse(BackgroundRecoveryProtocol.recovered(record(11), receipt::get, receipt::containsKey))
        receipt.remove(Proto.DISPLAY_ID)
        assertFalse(BackgroundRecoveryProtocol.recovered(record(null), receipt::get, receipt::containsKey))
        receipt[Proto.RECOVERY_KIND] = "previousBoot"
        assertTrue(BackgroundRecoveryProtocol.recovered(record(null), receipt::get, receipt::containsKey))
        receipt[Proto.DISPLAY_ID] = null
        assertFalse(BackgroundRecoveryProtocol.recovered(record(null), receipt::get, receipt::containsKey))
    }

    @Test fun retireProofIsOnlyTheExactPeerRetiredReceipt() {
        val receipt = mutableMapOf<String, Any?>(Proto.OK to true,
            Proto.RESOURCE_RECOVERY_VERSION to 1, Proto.RECOVERY_PEER to peer,
            Proto.RECOVERY_KIND to "peerRetired")
        assertTrue(BackgroundRecoveryProtocol.retired(peer, receipt::get))
        receipt[Proto.RECOVERY_PEER] = boot
        assertFalse(BackgroundRecoveryProtocol.retired(peer, receipt::get))
        receipt[Proto.RECOVERY_PEER] = peer; receipt[Proto.RECOVERY_KIND] = "deadPeerEmpty"
        assertFalse(BackgroundRecoveryProtocol.retired(peer, receipt::get))
    }
}
