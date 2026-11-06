package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.PhoneAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class BackgroundDisplayTest {
    @Test fun aFailedObservationReportsItsReasonAndInvalidatesOldElementNumbers() {
        for (code in listOf("treeUnavailable", "displayTargetChanged", "displayMissing", "systemOperationDenied")) {
            val display = withLastElement()
            assertNotNull(display.target("b7", 1))

            val failure = assertThrows(IllegalStateException::class.java) {
                display.requireObservation(false, code, null)
            }

            assertEquals(Reasons.of(code), failure.message)
            assertNull(display.target("b7", 1))
            assertNull(display.target("b8", 1))
        }
    }

    @Test fun aFailedObservationPreservesTheExistingExceptionTypeDetail() {
        val display = withLastElement()

        val failure = assertThrows(IllegalStateException::class.java) {
            display.requireObservation(false, "deviceUnavailable", "IllegalAccessException")
        }

        assertEquals(Reasons.of("deviceUnavailable", "IllegalAccessException"), failure.message)
        assertNull(display.target("b7", 1))
    }

    @Test fun aSuccessfulObservationMayProceedToDecodeItsSnapshot() {
        val display = withLastElement()

        display.requireObservation(true, null, null)

        // The decoder, not this response guard, replaces successful snapshots.
        assertNotNull(display.target("b7", 1))
    }

    private fun withLastElement(): BackgroundDisplay {
        val display = BackgroundDisplay(
            channelProvider = { error("response validation must not start a connection") },
            releaseChannelProvider = { error("response validation must not release the display") },
        )
        BackgroundDisplay::class.java.getDeclaredField("lastScreenId").apply {
            isAccessible = true
            set(display, "b7")
        }
        BackgroundDisplay::class.java.getDeclaredField("lastElements").apply {
            isAccessible = true
            set(display, listOf(Element(1, "按钮", "确定", Region.MIDDLE)))
        }
        return display
    }

    @Test fun onlyBackIsSentToTheBackgroundScreen() {
        val display = BackgroundDisplay(
            channelProvider = { error("a refused key must not reach the privileged channel") },
            releaseChannelProvider = { error("a refused key must not release the background screen") },
        )
        // An app is open on the background screen (set directly: opening one needs the channel).
        BackgroundDisplay::class.java.getDeclaredField("currentPackage").apply {
            isAccessible = true
            set(display, "example.opened")
        }

        for (key in PhoneAction.GlobalKey.entries - PhoneAction.GlobalKey.BACK) {
            val result = display.perform(PhoneAction.Key("b1", key))
            assertFalse(key.name, result.ok)
            assertEquals("后台屏不支持该系统键，未执行；请用返回或打开指定应用", result.message)
        }
    }
}
