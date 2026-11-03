package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.PhoneAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class BackgroundDisplayTest {
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
