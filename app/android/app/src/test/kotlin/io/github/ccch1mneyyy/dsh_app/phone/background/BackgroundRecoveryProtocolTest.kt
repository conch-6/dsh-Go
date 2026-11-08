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
        assertEquals(birth, BackgroundRecoveryProtocol.birth(cap::get))
        cap[Proto.RECOVERY_PID] = 42L
        assertNull(BackgroundRecoveryProtocol.birth(cap::get))
        cap[Proto.RECOVERY_PID] = 42; cap.remove(Proto.RECOVERY_PID_NS_INO)
        assertNull(BackgroundRecoveryProtocol.birth(cap::get))
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
