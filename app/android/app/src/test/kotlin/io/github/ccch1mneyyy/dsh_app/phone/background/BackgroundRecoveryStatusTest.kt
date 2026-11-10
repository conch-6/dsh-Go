package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundRecoveryStatusTest {
    @Test fun lostCurrentProcessSlotIsRetryableEvenThoughTheJournalHasNoOldRecords() {
        val saved = BackgroundResourceJournal.Snapshot("clear", 1, null, false)
        val status = BackgroundControl.resourceRecoveryStatus(saved, false, false, true, false)
        assertEquals("pending", status["state"])
        assertEquals(true, status["canRetry"])
        assertEquals("reconnectRequired", status["reason"])
        assertEquals(1, status["count"])
        val live = BackgroundControl.resourceRecoveryStatus(saved, false, false, false, true)
        assertEquals("clear", live["state"])
        assertEquals(false, live["canRetry"])
        assertNull(live["reason"])
    }

    @Test fun recoveryAndStorageErrorsKeepTheirExistingPriority() {
        val pending = BackgroundResourceJournal.Snapshot("pending", 2, "oldResources", false)
        val running = BackgroundControl.resourceRecoveryStatus(pending, true, false, true, true)
        assertEquals("recovering", running["state"])
        assertEquals(false, running["canRetry"])
        assertEquals("oldResources", running["reason"])
        val error = BackgroundControl.resourceRecoveryStatus(
            BackgroundResourceJournal.Snapshot("error", 1, "storageWriteFailed", true), false, false, true, false)
        assertEquals("error", error["state"])
        assertEquals(true, error["canRetry"])
        assertEquals("storageWriteFailed", error["reason"])
        val retired = BackgroundControl.resourceRecoveryStatus(
            BackgroundResourceJournal.Snapshot("clear", 0, null, false), false, true, false, false)
        assertEquals("pending", retired["state"])
        assertEquals(true, retired["canRetry"])
    }
}
