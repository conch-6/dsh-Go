package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

/** Uses the production gate call and real I/O worker; peer callbacks are not Android simulation. */
class BackgroundGateCallTest {
    private fun call(peer: Any = Any()): BackgroundGateCall<Any> {
        val gate = BackgroundGateState()
        return BackgroundGateCall(peer, gate.begin { true }!!,
            BackgroundResourceJournal({ null }, { true }).apply { load() })
    }

    @Test fun lostBeginReplyAndFailedReleaseRetainOriginalPeerWithoutRepeatingBegin() {
        val call = call()
        var begins = 0
        val attempts = mutableListOf<Pair<Any, String>>()
        try {
            call.io.call<Unit> { call.io.startResource<Unit>(call.peer, { beforeSend -> beforeSend(); begins++; throw java.io.IOException("lost reply") }) { true } }
            fail("the real I/O call must propagate its missing reply")
        } catch (_: java.io.IOException) { }
        assertFalse(call.finishProbeAndCleanup { peer, owner -> attempts += peer to owner; false })
        assertEquals("unknown", call.status()["state"])
        assertEquals(true, call.status()["canRetry"])
        assertTrue(call.retryCleanup { peer, owner ->
            attempts += peer to owner
            BackgroundReleaseReceipt.accepts(call.io.owner, 1, owner, true, true, true)
        })
        assertEquals(1, begins)
        assertEquals(2, attempts.size)
        attempts.forEach { assertSame(call.peer, it.first); assertEquals(call.io.owner, it.second) }
        assertFalse(call.retryCleanup { _, _ -> fail("completed cleanup must not repeat IPC"); true })
    }

    @Test fun callerInterruptionAndSealWaitForActualReplyBeforeCleanup() {
        val call = call()
        val entered = CountDownLatch(1)
        val reply = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val sawReply = AtomicBoolean()
        val releasedAfterReply = AtomicBoolean()
        val interrupted = AtomicBoolean()
        val worker = Thread {
            try {
                call.io.call { call.io.startResource(call.peer, { beforeSend -> beforeSend(); entered.countDown(); reply.await(); sawReply.set(true) }) { true } }
            } finally {
                interrupted.set(Thread.currentThread().isInterrupted)
                call.finishProbeAndCleanup { peer, owner ->
                    assertSame(call.peer, peer)
                    releasedAfterReply.set(sawReply.get())
                    BackgroundReleaseReceipt.accepts(call.io.owner, 1, owner, true, true, true)
                }
                completed.countDown()
            }
        }
        worker.start()
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            worker.interrupt()
            call.io.seal()
            assertFalse(call.retryCleanup { _, _ -> fail("in-flight begin cannot release early"); true })
            assertEquals("pending", call.status()["state"])
        } finally { reply.countDown() }
        assertTrue(completed.await(2, TimeUnit.SECONDS))
        worker.join(2000)
        assertTrue(interrupted.get())
        assertTrue(releasedAfterReply.get())
        assertEquals("idle", call.status()["state"])
    }

    @Test fun cancellationBeforePinUsesUnusedCompletionWithoutReleaseOrAllocation() {
        val call = call()
        val cap = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        val done = CountDownLatch(1)
        val began = AtomicInteger()
        val cleaned = AtomicBoolean()
        val thread = Thread {
            try {
                call.io.call { cap.countDown(); proceed.await(); call.io.startResource(call.peer, { beforeSend -> beforeSend(); began.incrementAndGet() }) { true } }
            } catch (_: IllegalStateException) {
                // Real pin admission was sealed between cap and the only begin.
            } finally {
                cleaned.set(call.finishProbeAndCleanup { _, _ -> fail("never pinned: no release RPC"); false })
                done.countDown()
            }
        }
        thread.start()
        try { assertTrue(cap.await(2, TimeUnit.SECONDS)); call.io.seal() }
        finally { proceed.countDown() }
        assertTrue(done.await(2, TimeUnit.SECONDS))
        thread.join(2000)
        assertEquals(0, began.get())
        assertTrue(cleaned.get())
    }

    @Test fun onlyOneRetryClaimsPhysicalCleanupAndDeadPeerDoesNotLookReleased() {
        val call = call()
        call.io.call { call.io.startResource(call.peer, { beforeSend -> beforeSend(); Unit }) { true } }
        assertFalse(call.finishProbeAndCleanup { _, _ -> false })
        assertEquals("unknown", call.status()["state"])
        assertEquals(true, call.status()["canRetry"])
        val entered = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        val done = CountDownLatch(1)
        val releases = AtomicInteger()
        val thread = Thread {
            try { call.retryCleanup { _, _ -> releases.incrementAndGet(); entered.countDown(); proceed.await(); true } }
            finally { done.countDown() }
        }
        thread.start()
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            assertEquals("cleaning", call.status()["state"])
            assertFalse(call.retryCleanup { _, _ -> releases.incrementAndGet(); true })
        } finally { proceed.countDown() }
        assertTrue(done.await(2, TimeUnit.SECONDS))
        thread.join(2000)
        assertEquals(1, releases.get())
    }
    @Test fun deadGateRecoveryUsesExactOriginalRecordAndNeverReleasesReplacement() {
        val pin = AtomicBoolean(true)
        val gate = BackgroundGateState()
        val journal = BackgroundResourceJournal({ null }, { true }).apply { load() }
        val call = BackgroundGateCall(pin, gate.begin { true }!!, journal)
        val birth = BackgroundResourceJournal.Birth(
            "00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002", 23, 0, 1L, 2L)
        call.io.call {
            assertTrue(call.resource.begin(birth))
            call.io.startResource(pin, { beforeSend -> beforeSend(); true }, { it })
            assertTrue(call.resource.allocated(41) { true })
        }
        val releases = AtomicInteger()
        assertFalse(call.finishProbeAndCleanup { _, _ -> releases.incrementAndGet(); false })
        var queries = 0
        fun receipt(id: Int): (BackgroundResourceJournal.Record) -> Boolean = { saved ->
            queries++
            assertEquals(call.io.owner, saved.owner)
            assertEquals(birth, saved.birth)
            assertEquals(41, saved.displayId)
            val reply = mapOf<String, Any?>(Proto.OK to true, Proto.RESOURCE_RECOVERY_VERSION to 1,
                Proto.RECOVERY_PEER to birth.peer, Proto.OWNER to call.io.owner,
                Proto.RECOVERY_KIND to "deadPeerEmpty", Proto.DISPLAY_ID to id)
            BackgroundRecoveryProtocol.recovered(saved, reply::get, reply::containsKey)
        }
        assertFalse(call.retryRecovery({ !it.get() }, receipt(41)))
        assertEquals(0, queries) // A live original pin is not bypassed by a replacement query.
        pin.set(false)
        assertFalse(call.retryRecovery({ !it.get() }, receipt(42)))
        assertFalse(call.resource.physicalComplete)
        assertEquals(1, journal.status().count)
        assertTrue(call.retryRecovery({ !it.get() }, receipt(41)))
        assertEquals(2, queries)
        assertEquals(1, releases.get()) // Only the original initial cleanup attempted RELEASE.
        assertTrue(call.resource.physicalComplete)
        assertEquals(0, journal.status().count)
        assertEquals("idle", call.status()["state"])
        assertFalse(call.retryRecovery({ true }) { fail("completed handle cannot query again"); true })
    }

    @Test fun replacementRecoveryCannotOvertakeProbeOrAnotherOriginalCleanup() {
        val call = call()
        assertFalse(call.retryRecovery({ true }) { fail("probe is still in flight"); true })
        call.io.call { call.io.startResource(call.peer, { beforeSend -> beforeSend(); Unit }) { true } }
        val entered = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val done = CountDownLatch(1)
        val worker = Thread {
            try { call.finishProbeAndCleanup { _, _ -> entered.countDown(); check(finish.await(5, TimeUnit.SECONDS)); false } }
            finally { done.countDown() }
        }
        worker.start()
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertFalse(call.retryRecovery({ true }) { fail("original cleanup owns the lane"); true })
        } finally { finish.countDown() }
        assertTrue(done.await(5, TimeUnit.SECONDS))
        worker.join(5000)
        assertEquals("unknown", call.status()["state"])
        assertTrue(call.retryCleanup { _, _ -> true })
    }

}
