package io.github.ccch1mneyyy.dsh_app.phone

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

/** Exercise the real Callable boundary with a controllable clock, not a copied state machine. */
class SerialWorkerAdmissionTest {
    @Test fun queuedDeadlineWinningBeforeBodyClaimPreventsLateExecution() {
        val time = AtomicLong(1_000)
        val atClock = CountDownLatch(1)
        val clockReply = CountDownLatch(1)
        val clockCalls = AtomicInteger()
        val bodyCalls = AtomicInteger()
        val worker = SerialWorker("admission-clock", {
            if (Thread.currentThread().name.startsWith("admission-clock-") && clockCalls.getAndIncrement() == 0) {
                atClock.countDown()
                check(clockReply.await(5, TimeUnit.SECONDS))
            }
            time.get()
        }) { false }
        val caller = Executors.newSingleThreadExecutor()
        try {
            val result = caller.submit<SerialWorker.Outcome<Int>> { worker.run(10_000, 100, Any()) { bodyCalls.incrementAndGet() } }
            assertTrue(atClock.await(5, TimeUnit.SECONDS))
            time.addAndGet(1_000)
            val timeout = result.get(5, TimeUnit.SECONDS)
            assertTrue(timeout is SerialWorker.Outcome.TimedOut && timeout.queued)
            assertEquals(0, bodyCalls.get())
            clockReply.countDown()
            // This real next call must pass the old Callable in the same executor queue.
            val next = worker.run(10_000, 10_000) { 23 }
            assertTrue(next is SerialWorker.Outcome.Done && next.value == 23)
            assertEquals("the cancelled pre-claim body must never run later", 0, bodyCalls.get())
        } finally { clockReply.countDown(); caller.shutdownNow(); worker.shutdown() }
    }

    @Test fun claimedBodyAtZeroClockIsNeverReportedAsQueuedAndRetainsPhysicalDrain() {
        val time = AtomicLong(0) // Zero is a valid starting timestamp, not a QUEUED sentinel.
        val entered = CountDownLatch(1)
        val bodyReply = CountDownLatch(1)
        val drained = CountDownLatch(1)
        val owner = Any()
        val worker = SerialWorker("admission-running", time::get) { false }
        val caller = Executors.newSingleThreadExecutor()
        try {
            val result = caller.submit<SerialWorker.Outcome<Int>> {
                worker.run(10_000, 100, owner) {
                    entered.countDown()
                    // Simulates a platform body which still owns physical work after cancellation.
                    while (true) {
                        try { if (bodyReply.await(5, TimeUnit.SECONDS)) break else error("test reply missing") }
                        catch (_: InterruptedException) { }
                    }
                    42
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            time.addAndGet(1_000)
            val timeout = result.get(5, TimeUnit.SECONDS)
            assertTrue(timeout is SerialWorker.Outcome.TimedOut && !timeout.queued)
            worker.afterDrained(owner) { drained.countDown() }
            assertEquals(1L, drained.count)
            bodyReply.countDown()
            assertTrue(drained.await(5, TimeUnit.SECONDS))
        } finally { bodyReply.countDown(); caller.shutdownNow(); worker.shutdown() }
    }
}
