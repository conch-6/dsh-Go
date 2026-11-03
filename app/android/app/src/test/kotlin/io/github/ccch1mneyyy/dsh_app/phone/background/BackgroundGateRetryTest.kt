package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class BackgroundGateRetryTest {
    private class Unconfirmed : Exception()
    private class Denied : Exception()

    private var clock = 0L
    private var attempts = 0

    private fun run(attempt: () -> Unit) = BackgroundPolicy.retryUntil(
        timeoutMs = 1000, pauseMs = 100, now = { clock }, pause = { clock += it },
        retry = { it is Unconfirmed },
    ) { attempts++; attempt() }

    // A tap right after the display is created reports false, one a moment later lands (#362).
    @Test fun anUnconfirmedAttemptIsRepeatedUntilOneLands() {
        run { if (attempts < 3) throw Unconfirmed() }
        assertEquals(3, attempts)
        assertEquals(200L, clock)
    }

    @Test fun aFailureThatIsNotUnconfirmedIsNeverRepeated() {
        val denied = Denied()
        assertSame(denied, assertThrows(Denied::class.java) { run { throw denied } })
        assertEquals(1, attempts)
        assertEquals(0L, clock)
    }

    @Test fun anAttemptThatNeverLandsStopsAtTheDeadlineWithItsOwnFailure() {
        assertThrows(Unconfirmed::class.java) { run { throw Unconfirmed() } }
        assertEquals(11, attempts)
        assertEquals(1000L, clock)
    }
}
