package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.phone.*
import org.junit.Assert.*
import org.junit.Test

class ScreenFormatTest {
    private fun format(vararg nodes: UiNode): FormattedScreen {
        val bounds = Box(0, 0, 400, 800)
        return ScreenFormat.format(ScreenInput("s1", "Example", "example.app", 400, 800, false,
            listOf(UiWindow(1, WindowKind.APP, "example.app", null, bounds, UiNode(bounds = bounds, children = nodes.toList())))))
    }

    @Test fun passwordContentsNeverAppearAndCodesAreSecret() {
        val screen = format(
            UiNode(className = "android.widget.EditText", text = "never-visible-password", hint = "密码",
                bounds = Box(0, 100, 300, 150), editable = true, password = true),
            UiNode(className = "android.widget.EditText", text = "123456", hint = "验证码",
                bounds = Box(0, 200, 300, 250), editable = true),
        )
        assertFalse(screen.text.contains("never-visible-password"))
        assertFalse(screen.text.contains("123456"))
        assertTrue(screen.elements.any { it.password })
        assertTrue(screen.elements.any { it.secret && !it.password })
    }

    @Test fun warningMarkerAndWriteGateUseTheSameSensitiveSource() {
        val screen = format(UiNode(className = "android.widget.Button", text = "发送",
            bounds = Box(0, 100, 300, 150), clickable = true))
        val element = screen.elements.single()
        assertTrue(screen.text.contains("⚠"))
        val tasks = PhoneTasks().apply { begin(); approve("example.app") }
        val gate = SafetyGate({ PhonePolicies() }, tasks, { null })
        val target = TargetInfo("s1", element.id, element.role, element.label, "example.app", "Example",
            element.password, element.secret, element.editable, element.viewId)
        val verdict = gate.checkWrite(WriteKind.TAP, target, "example.app", "Example") as SafetyGate.Verdict.Confirm
        assertEquals("sensitive:${element.sensitiveWord}", verdict.reason)
    }

    @Test fun anUnreadableWindowIsNotCalledAPoorTree() {
        val frame = Box(0, 0, 400, 800)
        val windows = listOf(UiWindow(1, WindowKind.APP, "com.github.android", "GitHub", frame, UiNode(bounds = frame)))
        val unreadable = ScreenFormat.format(
            ScreenInput("s1", "GitHub", "com.github.android", 400, 800, false, windows,
                notes = listOf("提示：这一屏读不到"), unreadable = true),
        )
        assertFalse(unreadable.text.contains(ScreenFormat.POOR_TREE_NOTE))
        assertTrue(unreadable.text.contains("这一屏读不到"))

        // 同样的空树,没有"被过滤"的证据时,照旧说文字信息不足。
        val poor = ScreenFormat.format(ScreenInput("s2", "GitHub", "com.github.android", 400, 800, false, windows))
        assertTrue(poor.text.contains(ScreenFormat.POOR_TREE_NOTE))
    }

    @Test fun screenshotMasksIncludeFieldsOutsideTheTextBudget() {
        val frame = Box(0, 0, 400, 800)
        val passwordBox = Box(0, 500, 300, 550)
        val codeBox = Box(0, 600, 300, 650)
        val root = UiNode(bounds = frame, children = listOf(
            UiNode(bounds = passwordBox, password = true, editable = true),
            UiNode(bounds = codeBox, text = "验证码", showingHint = true, editable = true),
            UiNode(bounds = Box(0, 100, 300, 150), text = "ordinary", editable = true),
        ))
        val windows = listOf(UiWindow(1, WindowKind.APP, "example.app", null, frame, root))
        assertEquals(listOf(passwordBox, codeBox), ScreenShooter.sensitiveBounds(windows))
    }

}
