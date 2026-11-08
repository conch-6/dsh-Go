package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class PrivilegedCallsTest {
    @Test fun previewSkipsAnActiveAgentWithoutQueuingWork() {
        val calls = PrivilegedCalls()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val agent = executor.submit<String> {
                calls.execute { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); "agent" }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val previewRan = AtomicBoolean(false)
            assertNull(calls.tryPreview { previewRan.set(true); "frame" })
            release.countDown()
            assertEquals("agent", agent.get(5, TimeUnit.SECONDS))
            assertFalse(previewRan.get())
            assertEquals("frame", calls.tryPreview { "frame" })
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun cancelledWaitingAgentDoesNotDispatchOrRetireTheSentPreview() {
        val calls = PrivilegedCalls()
        val previewEntered = CountDownLatch(1)
        val releasePreview = CountDownLatch(1)
        val agentStarted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        val agentDispatched = AtomicBoolean(false)
        try {
            val preview = executor.submit<String?> {
                calls.tryPreview { previewEntered.countDown(); check(releasePreview.await(5, TimeUnit.SECONDS)); "complete response" }
            }
            assertTrue(previewEntered.await(5, TimeUnit.SECONDS))
            val agent = executor.submit {
                agentStarted.countDown()
                calls.execute { agentDispatched.set(true) }
            }
            assertTrue(agentStarted.await(5, TimeUnit.SECONDS))
            agent.cancel(true)
            releasePreview.countDown()
            assertEquals("complete response", preview.get(5, TimeUnit.SECONDS))
            assertFalse(agentDispatched.get())
            assertEquals("next", calls.execute { "next" })
        } finally {
            releasePreview.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun failedPreviewReleasesAdmissionForTheNextAgent() {
        val calls = PrivilegedCalls()
        try {
            calls.tryPreview<Unit> { throw IllegalStateException("synthetic failure") }
            fail("expected failure")
        } catch (_: IllegalStateException) { }
        assertEquals("agent", calls.execute { "agent" })
    }
}
