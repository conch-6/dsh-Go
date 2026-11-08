package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Exercises the actual controller slot with real task lifetimes and physical IO admission. */
class BackgroundTaskSlotTest {
    private fun begin(tasks: PhoneTasks) = (tasks.begin() as PhoneTasks.Begin.Go).owner

    @Test fun repeatedOwnerValuesAndOrdinaryPauseKeepTheOriginalDriver() {
        val tasks = PhoneTasks(clock = { 100L })
        val slot = BackgroundTaskSlot<Any>(Any())
        val owner = begin(tasks)
        val driver = Any()
        val original = slot.acquire(owner, { tasks.isCurrent(owner) }) { driver }!!
        tasks.setPaused(true)
        tasks.setPaused(false)
        val again = begin(tasks)
        assertNotSame(owner, again)
        assertEquals(owner.lifecycle, again.lifecycle)
        assertSame(original, slot.acquire(again, { tasks.isCurrent(again) }) { error("must not construct") })
        assertSame(driver, slot.find(again)?.driver)
    }

    @Test fun anotherTaskOrNewLifecycleCannotDisplaceAnOccupiedResource() {
        val tasks = PhoneTasks(clock = { 100L }, idSource = { 50L })
        val other = PhoneTasks(clock = { 100L }, idSource = { 4L })
        val slot = BackgroundTaskSlot<Any>(Any())
        val owner = begin(tasks); val otherOwner = begin(other)
        val original = slot.acquire(owner, { tasks.isCurrent(owner) }) { Any() }!!
        assertNull(slot.acquire(otherOwner, { other.isCurrent(otherOwner) }) { error("no eviction") })
        tasks.invalidateOwners()
        val newLife = tasks.activeOwner()!!
        assertEquals(owner.taskId, newLife.taskId)
        assertNotEquals(owner.lifecycle, newLife.lifecycle)
        assertNull(slot.acquire(newLife, { tasks.isCurrent(newLife) }) { error("old resource remains") })
        assertSame(original, slot.seal(owner.taskId))
        assertTrue(slot.complete(original))
        // No numerical high-water rule: a different live lower id can now occupy the free slot.
        assertNotNull(slot.acquire(otherOwner, { other.isCurrent(otherOwner) }) { Any() })
    }

    @Test fun stopDuringConnectionPreventsTheDelayedRegistration() {
        val tasks = PhoneTasks(clock = { 100L })
        val owner = begin(tasks)
        val slot = BackgroundTaskSlot<Any>(Any())
        val connecting = CountDownLatch(1); val connected = CountDownLatch(1)
        val pool = Executors.newSingleThreadExecutor()
        try {
            val call = pool.submit<BackgroundTaskSlot.TaskResource<Any>?> {
                connecting.countDown(); check(connected.await(5, TimeUnit.SECONDS))
                slot.acquire(owner, { tasks.isCurrent(owner) }) { error("stopped setup must not publish") }
            }
            assertTrue(connecting.await(5, TimeUnit.SECONDS))
            tasks.stop("stop")
            assertNull(slot.seal(owner.taskId)) // No record yet, and no fabricated high-water fence.
            connected.countDown()
            assertNull(call.get(5, TimeUnit.SECONDS))
            assertFalse(slot.occupied)
        } finally { connected.countDown(); pool.shutdownNow() }
    }

    @Test fun stopDuringConstructionSealsThePublishedOriginalAfterTheSameMonitor() {
        val tasks = PhoneTasks(clock = { 100L }); val owner = begin(tasks)
        val lock = Any(); val slot = BackgroundTaskSlot<Any>(lock)
        val constructing = CountDownLatch(1); val finish = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val acquire = pool.submit<BackgroundTaskSlot.TaskResource<Any>?> {
                slot.acquire(owner, { tasks.isCurrent(owner) }) {
                    constructing.countDown(); check(finish.await(5, TimeUnit.SECONDS)); Any()
                }
            }
            assertTrue(constructing.await(5, TimeUnit.SECONDS))
            tasks.stop("stop")
            val cleanup = pool.submit<BackgroundTaskSlot.TaskResource<Any>?> { slot.seal(owner.taskId) }
            finish.countDown()
            val original = acquire.get(5, TimeUnit.SECONDS)!!
            assertSame(original, cleanup.get(5, TimeUnit.SECONDS))
            assertNull(slot.find(owner))
            assertTrue(slot.occupied)
            assertTrue(slot.complete(original))
        } finally { finish.countDown(); pool.shutdownNow() }
    }

    @Test fun cancelledOwnerAndUnknownPhysicalReleaseKeepTheOriginalSlotUntilRetry() {
        val tasks = PhoneTasks(clock = { 100L }); val owner = begin(tasks)
        val slot = BackgroundTaskSlot<BackgroundDisplayIo<Any>>(Any())
        val original = slot.acquire(owner, { tasks.isCurrent(owner) }) { BackgroundDisplayIo() }!!
        val io = original.driver; val peer = Any()
        io.call { io.startResource(peer, { beforeSend -> beforeSend(); true }) { it } }
        tasks.stop("stop")
        assertSame(original, slot.seal(owner.taskId))
        io.seal()
        assertFalse(io.release { assertSame(peer, it); false })
        assertTrue(slot.occupied) // Gate/selfcheck/interrupt use this same occupied fact.
        assertFalse(slot.current(original)) // A late preview publication cannot revive it.
        assertNull(slot.find(owner))
        val other = PhoneTasks(clock = { 100L }, idSource = { 8L }); val otherOwner = begin(other)
        assertNull(slot.acquire(otherOwner, { other.isCurrent(otherOwner) }) { error("unknown retains slot") })
        assertTrue(io.release { assertSame(peer, it); true })
        assertTrue(slot.complete(original))
        assertFalse(slot.occupied)
    }

    @Test fun aLateCleanupCommitOrPreviewCannotTargetTheSuccessorRecord() {
        val slot = BackgroundTaskSlot<Any>(Any())
        val first = PhoneTasks(clock = { 100L }, idSource = { 1L }); val a = begin(first)
        val old = slot.acquire(a, { first.isCurrent(a) }) { Any() }!!
        assertSame(old, slot.seal(a.taskId))
        assertTrue(slot.complete(old))
        val second = PhoneTasks(clock = { 100L }, idSource = { 2L }); val b = begin(second)
        val next = slot.acquire(b, { second.isCurrent(b) }) { Any() }!!
        assertFalse(slot.complete(old))
        assertFalse(slot.current(old))
        assertNull(slot.seal(a.taskId))
        assertSame(next, slot.find(b))
        assertTrue(slot.current(next))
    }
}
