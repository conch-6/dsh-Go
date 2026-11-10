package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.Json
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class BackgroundResourceJournalTest {
    private val process = "00000000-0000-0000-0000-000000000001"
    private val restarted = "00000000-0000-0000-0000-000000000002"
    private val birth = BackgroundResourceJournal.Birth(
        "10000000-0000-0000-0000-000000000001",
        "20000000-0000-0000-0000-000000000001", 42, 2000, 7L, 9L)

    private class Store {
        val raw = AtomicReference<String?>(null)
        val writes = AtomicInteger()
        val fail = AtomicBoolean(false)
        fun commit(value: String): Boolean {
            writes.incrementAndGet()
            if (fail.get()) return false
            raw.set(value)
            return true
        }
    }
    private fun journal(store: Store, current: String = process) =
        BackgroundResourceJournal({ store.raw.get() }, store::commit, current)

    private fun changeStoredBirth(raw: String, values: Map<String, Any?>): String {
        val root = Json.parse(raw) as Map<*, *>
        val record = (root["records"] as List<*>).single() as Map<*, *>
        return Json.write(root + mapOf("records" to listOf(record + values)))
    }

    @Test fun namespaceUnavailableStillAllowsOriginalScopeAllocationAndPhysicalCleanup() {
        val store = Store()
        val journal = journal(store)
        assertTrue(journal.load())
        val unavailable = birth.copy(pidNsDev = 0L, pidNsIno = 0L, pidNsAvailable = false)
        val io = BackgroundDisplayIo<Any>()
        val scope = BackgroundResourceScope(io, journal, "probe")
        try {
            io.call {
                assertTrue(scope.begin(unavailable))
                assertTrue(io.startResource(Any(), { beforeSend -> beforeSend(); true }, { it }))
                assertTrue(scope.allocated(11) { true })
            }
            assertTrue(scope.allocationReady)
            val next = journal(store, restarted)
            assertTrue(next.load())
            assertEquals(unavailable, next.oldRecords()!!.single().birth)
            assertEquals("pending", next.status().state)
            assertTrue(next.retryStorage())
            assertEquals("pending", next.status().state)
            assertFalse(next.closed(next.oldRecords()!!.single()))
            assertTrue(scope.cleanup { true })
            assertEquals(0, journal.status().count)
        } finally { scope.cleanup { true } }
    }

    @Test fun legacyKnownNamespaceShapeRemainsReadableAndUnchangedOnWrite() {
        val store = Store()
        val original = journal(store)
        assertTrue(original.load())
        assertTrue(original.mark(original.record(UUID.randomUUID().toString(), "probe", birth, null)))
        val legacy = store.raw.get()!!
        assertFalse(legacy.contains("recoveryPidNsAvailable"))
        val next = journal(store, restarted)
        assertTrue(next.load())
        assertEquals(birth, next.oldRecords()!!.single().birth)
        store.raw.set(changeStoredBirth(legacy, mapOf("recoveryPidNsAvailable" to true)))
        val explicit = journal(store, restarted)
        assertTrue(explicit.load())
        assertEquals(birth, explicit.oldRecords()!!.single().birth)
    }

    @Test fun namespaceSentinelsAndOptionalFieldTypesAreStrictOnDurableRead() {
        val store = Store()
        val original = journal(store)
        assertTrue(original.load())
        assertTrue(original.mark(original.record(UUID.randomUUID().toString(), "probe", birth, null)))
        val known = store.raw.get()!!
        val zero = mapOf("recoveryPidNsDev" to 0L, "recoveryPidNsIno" to 0L)
        for (values in listOf(
            mapOf("recoveryPidNsAvailable" to null), mapOf("recoveryPidNsAvailable" to 0L),
            mapOf("recoveryPidNsAvailable" to "false"), mapOf("recoveryPidNsAvailable" to false),
            zero, zero + ("recoveryPidNsAvailable" to true),
            zero + mapOf("recoveryPidNsAvailable" to false, "recoveryPidNsDev" to 7L),
            zero + mapOf("recoveryPidNsAvailable" to false, "recoveryPidNsIno" to 9L),
            mapOf("unknownNamespace" to false),
        )) {
            store.raw.set(changeStoredBirth(known, values))
            val next = journal(store, restarted)
            assertFalse(next.load())
            assertNull(next.oldRecords())
            assertEquals("storageReadFailed", next.status().reason)
            assertEquals(1, store.writes.get())
        }
        for ((dev, ino, available) in listOf(Triple(7L, 0L, true), Triple(7L, 9L, false), Triple(0L, 9L, false))) {
            try {
                birth.copy(pidNsDev = dev, pidNsIno = ino, pidNsAvailable = available)
                fail("Invalid namespace birth must be rejected")
            } catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun unavailableOldRecordsCanStillUseExactOriginalPeerRetirementProof() {
        val store = Store()
        val original = journal(store)
        assertTrue(original.load())
        val unavailable = birth.copy(pidNsDev = 0L, pidNsIno = 0L, pidNsAvailable = false)
        assertTrue(original.mark(original.record(UUID.randomUUID().toString(), "probe", unavailable, null)))
        val next = journal(store, restarted)
        assertTrue(next.load())
        val group = next.oldRecords()!!
        assertFalse(group.single().birth.pidNsAvailable)
        assertTrue(next.recoveredPeer(unavailable.peer, group))
        assertEquals("clear", next.status().state)
        assertEquals(0, next.status().count)
    }

    @Test fun currentActiveDoesNotBlockButRestartedRecordBlocksWithoutBeingAcknowledged() {
        val store = Store()
        val first = journal(store)
        assertTrue(first.load())
        val record = first.record(UUID.randomUUID().toString(), "task", birth, "portrait")
        assertTrue(first.mark(record))
        assertTrue(first.allocated(record, 11))
        assertEquals("clear", first.status().state)
        val next = journal(store, restarted)
        assertTrue(next.load())
        assertEquals("pending", next.status().state)
        assertTrue(next.retryStorage())
        assertNotEquals("clear", next.status().state)
        val old = next.oldRecords()!!.single()
        assertEquals(11, old.displayId)
        assertFalse(next.closed(old))
        assertNotEquals("clear", next.status().state)
    }

    @Test fun failedIntentRetainsItsExactCandidateUntilProvenUnusedAndCommitted() {
        val store = Store()
        val journal = journal(store)
        assertTrue(journal.load())
        val record = journal.record(UUID.randomUUID().toString(), "probe", birth, null)
        store.fail.set(true)
        assertFalse(journal.mark(record))
        assertEquals(1, journal.status().count)
        assertNotEquals("clear", journal.status().state)
        assertFalse(journal.closed(record))
        store.fail.set(false)
        assertTrue(journal.retryStorage())
        assertEquals(0, journal.status().count)
        assertEquals("clear", journal.status().state)
    }

    @Test fun failedDeleteKeepsProofAndCannotDeleteAnotherOriginalOwner() {
        val store = Store()
        val journal = journal(store)
        assertTrue(journal.load())
        val a = journal.record(UUID.randomUUID().toString(), "probe", birth, null)
        val b = journal.record(UUID.randomUUID().toString(), "target", birth, null)
        assertTrue(journal.mark(a))
        assertTrue(journal.allocated(a, 11))
        assertTrue(journal.mark(b))
        assertTrue(journal.allocated(b, 12))
        store.fail.set(true)
        assertFalse(journal.closed(a))
        assertEquals("error", journal.status().state)
        store.fail.set(false)
        assertTrue(journal.retryStorage())
        assertEquals(1, journal.status().count)
        assertTrue(journal.hasCurrentResources())
        val next = journal(store, restarted)
        assertTrue(next.load())
        assertEquals(b.owner, next.oldRecords()!!.single().owner)
        assertTrue(journal.closed(b))
    }

    @Test fun recoveryDeletionRequiresTheExactOldSnapshotAndSurvivesCommitFailure() {
        val store = Store()
        val old = journal(store)
        assertTrue(old.load())
        val initial = old.record(UUID.randomUUID().toString(), "task", birth, "landscape")
        assertTrue(old.mark(initial))
        assertTrue(old.allocated(initial, 17))
        val current = journal(store, restarted)
        assertTrue(current.load())
        val saved = current.oldRecords()!!.single()
        assertFalse(current.recovered(saved.copy(displayId = 18)))
        assertNotEquals("clear", current.status().state)
        store.fail.set(true)
        assertFalse(current.recovered(saved))
        assertEquals(1, current.status().count)
        store.fail.set(false)
        assertTrue(current.retryStorage())
        assertEquals(0, current.status().count)
        assertEquals("clear", current.status().state)
    }

    @Test fun readFailureNeverLooksEmptyAndFullBudgetStillPermitsOriginalCleanup() {
        val store = Store()
        store.raw.set("{invalid")
        val broken = journal(store)
        assertFalse(broken.load())
        assertEquals("error", broken.status().state)
        assertNotEquals("clear", broken.status().state)
        store.raw.set(null)
        assertTrue(broken.retryStorage())
        val records = (1..256).map {
            broken.record(UUID.randomUUID().toString(), "probe", birth, null).also {
                assertTrue(broken.mark(it))
            }
        }
        val extra = broken.record(UUID.randomUUID().toString(), "probe", birth, null)
        assertFalse(broken.mark(extra))
        assertTrue(broken.closed(records.first()))
        assertTrue(broken.mark(extra))
    }

    @Test fun actualIoPinAndStorageRetryNeverPromoteFailedAllocationToReady() {
        val store = Store()
        val journal = journal(store)
        assertTrue(journal.load())
        val io = BackgroundDisplayIo<Any>()
        val scope = BackgroundResourceScope(io, journal, "task", "portrait")
        val peer = Any()
        try {
            io.call {
                assertTrue(scope.begin(birth))
                assertTrue(io.startResource(peer, { beforeSend -> beforeSend(); true }, { it }))
                store.fail.set(true)
                assertFalse(scope.allocated(21) { true })
            }
            assertFalse(scope.allocationReady)
            store.fail.set(false)
            assertTrue(journal.retryStorage())
            assertFalse(scope.allocationReady)
            assertFalse(scope.begin(birth))
            val next = journal(store, restarted)
            assertTrue(next.load())
            assertEquals(21, next.oldRecords()!!.single().displayId)
        } finally {
            store.fail.set(false)
            assertTrue(scope.cleanup { true })
        }
    }

    @Test fun physicalReleaseIsNotRepeatedWhenOnlyDurableDeleteNeedsRetry() {
        val store = Store()
        val journal = journal(store)
        assertTrue(journal.load())
        val io = BackgroundDisplayIo<Any>()
        val scope = BackgroundResourceScope(io, journal, "probe")
        val releases = AtomicInteger()
        io.call {
            assertTrue(scope.begin(birth))
            io.startResource(Any(), { beforeSend -> beforeSend(); true }, { it })
            assertTrue(scope.allocated(22) { true })
        }
        store.fail.set(true)
        assertFalse(scope.cleanup { releases.incrementAndGet(); true })
        assertTrue(scope.physicalComplete)
        assertFalse(scope.allocationReady)
        assertEquals(1, releases.get())
        assertFalse(scope.cleanup { releases.incrementAndGet(); true })
        assertEquals(1, releases.get())
        store.fail.set(false)
        assertTrue(scope.cleanup { releases.incrementAndGet(); true })
        assertEquals(1, releases.get())
        assertEquals(0, journal.status().count)
    }

    @Test fun lostOriginalPeerIsDischargedOnlyByAnExactAbsenceReceiptAfterItsWorkDrains() {
        val store = Store()
        val journal = journal(store)
        assertTrue(journal.load())
        val asked = mutableListOf<BackgroundResourceJournal.Record>()
        val releases = AtomicInteger()
        fun receipt(id: Int): (BackgroundResourceJournal.Record) -> Boolean = { saved ->
            asked.add(saved)
            val reply = mapOf<String, Any?>(Proto.OK to true, Proto.RESOURCE_RECOVERY_VERSION to 1,
                Proto.RECOVERY_PEER to saved.birth.peer, Proto.OWNER to saved.owner,
                Proto.RECOVERY_KIND to "deadPeerEmpty", Proto.DISPLAY_ID to id)
            BackgroundRecoveryProtocol.recovered(saved, reply::get, reply::containsKey)
        }
        fun pinnedScope(pin: AtomicBoolean, id: Int): Pair<BackgroundDisplayIo<AtomicBoolean>, BackgroundResourceScope<AtomicBoolean>> {
            val io = BackgroundDisplayIo<AtomicBoolean>()
            val scope = BackgroundResourceScope(io, journal, "task", "portrait")
            io.call {
                assertTrue(scope.begin(birth))
                io.startResource(pin, { beforeSend -> beforeSend(); true }, { it })
                assertTrue(scope.allocated(id) { true })
            }
            return io to scope
        }
        // A live original pin is never bypassed: strict RELEASE stays its only path.
        val (_, live) = pinnedScope(AtomicBoolean(true), 30)
        assertFalse(live.recover({ !it.get() }, receipt(30)))
        assertTrue(asked.isEmpty())
        assertTrue(live.cleanup { releases.incrementAndGet(); true })

        val pin = AtomicBoolean(true)
        val (io, scope) = pinnedScope(pin, 31)
        val entered = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val caller = Executors.newSingleThreadExecutor()
        try {
            val body = caller.submit<Unit> { io.call { entered.countDown(); check(finish.await(5, TimeUnit.SECONDS)) } }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            pin.set(false)
            // The original body has not drained: no receipt is even requested.
            assertFalse(scope.recover({ !it.get() }, receipt(31)))
            assertTrue(asked.isEmpty())
            finish.countDown()
            body.get(5, TimeUnit.SECONDS)
            // RELEASE cannot reach the dead pin, and old-record recovery never sees this process's record.
            assertFalse(scope.cleanup { false })
            assertEquals(emptyList<BackgroundResourceJournal.Record>(), journal.oldRecords())
            assertTrue(journal.hasCurrentResources())
            // A receipt for another display is not absence of this one.
            assertFalse(scope.recover({ !it.get() }, receipt(32)))
            assertEquals(31, asked.single().displayId)
            assertEquals(io.owner, asked.single().owner)
            assertFalse(scope.physicalComplete)
            assertEquals(1, journal.status().count)

            assertTrue(scope.recover({ !it.get() }, receipt(31)))
            assertTrue(scope.physicalComplete)
            assertFalse(journal.hasCurrentResources())
            assertEquals("clear", journal.status().state)
            // The later endTask cleanup reuses the cached completion and never sends RELEASE again.
            assertTrue(scope.cleanup { releases.incrementAndGet(); false })
            assertEquals(1, releases.get())
        } finally {
            finish.countDown()
            caller.shutdownNow()
        }
    }

    @Test fun cancellationDuringActualIdCommitWaitsForBodyAndNeverEnablesBusiness() {
        val raw = AtomicReference<String?>(null)
        val writes = AtomicInteger()
        val inCommit = CountDownLatch(1)
        val finishCommit = CountDownLatch(1)
        val journal = BackgroundResourceJournal({ raw.get() }, { value ->
            if (writes.incrementAndGet() == 2) {
                inCommit.countDown()
                check(finishCommit.await(5, TimeUnit.SECONDS))
            }
            raw.set(value)
            true
        }, process)
        assertTrue(journal.load())
        val io = BackgroundDisplayIo<Any>()
        val scope = BackgroundResourceScope(io, journal, "target")
        val live = AtomicBoolean(true)
        val business = AtomicInteger()
        val releases = AtomicInteger()
        val caller = Executors.newSingleThreadExecutor()
        try {
            val call = caller.submit<Boolean> {
                io.call {
                    check(scope.begin(birth))
                    io.startResource(Any(), { beforeSend -> beforeSend(); true }, { it })
                    val ready = scope.allocated(23) { live.get() }
                    if (ready) business.incrementAndGet()
                    ready
                }
            }
            assertTrue(inCommit.await(5, TimeUnit.SECONDS))
            live.set(false)
            assertFalse(scope.cleanup { releases.incrementAndGet(); true })
            assertEquals(0, releases.get())
            finishCommit.countDown()
            assertFalse(call.get(5, TimeUnit.SECONDS))
            assertFalse(scope.allocationReady)
            assertEquals(0, business.get())
            assertTrue(scope.cleanup { releases.incrementAndGet(); true })
            assertEquals(1, releases.get())
            assertEquals(0, journal.status().count)
        } finally {
            finishCommit.countDown()
            caller.shutdownNow()
            scope.cleanup { true }
        }
    }
}
