package io.github.ccch1mneyyy.dsh_app.phone

import java.time.ZoneId
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Actual PhoneCore -> worker -> gate -> driver path; Android device interfaces are fakes. */
class PhoneCorePromptOwnerTest {
    private val tasks = PhoneTasks()
    private var confirm: () -> Decision = { Decision.ALLOW_ONCE }
    private var handoff: () -> HandoffResult = { HandoffResult.CONTINUE }
    private var beforeHandoff: () -> Unit = {}
    private var asked = 0
    private val main = Driver(PhoneScreen.MAIN)
    private val background = Driver(PhoneScreen.BACKGROUND)
    private val core = PhoneCore(object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = PhonePolicies()
        override fun isLocked() = false
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest): Decision { asked++; return confirm() }
            override fun handoff(reason: String, timeoutMs: Long): HandoffResult { asked++; return handoff() }
            override fun status(text: String?) {}
        }
        override fun driver(screen: PhoneScreen) = if (screen == PhoneScreen.MAIN) main else background
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun beforeHandoff(screen: PhoneScreen): String? { beforeHandoff(); return null }
        override fun sleep(ms: Long) {}
        override fun system() = object : SystemApi {
            override fun apps() = listOf(AppEntry("Example", "example.app"))
            override fun isInstalled(pkg: String) = true
            override fun launch(app: AppEntry) = error("unexpected launch")
            override fun urlTarget(url: String) = error("unexpected URL")
            override fun openUrl(url: String, target: UrlTarget) = error("unexpected URL open")
            override fun intent(spec: IntentSpec, shareTo: AppEntry?) = error("unexpected intent")
            override fun notify(title: String, text: String) = error("unexpected notification")
            override fun clipboardSet(text: String) = error("unexpected clipboard")
            override fun clipboardGet() = error("unexpected clipboard")
        }
    }, tasks, ActionLog())

    private class Driver(override val screen: PhoneScreen) : PhoneDriver {
        var reads = 0
        var writes = 0
        var opens = 0
        val actions = mutableListOf<PhoneAction>()
        override fun availability() = Availability(true)
        override fun foregroundPackage() = "example.app"
        override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
            reads++
            return ScreenSnapshot("${screen.prefix}1", "Example", "Example", "example.app")
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unexpected collect")
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId,
            "按钮", "发送", "example.app", "Example", false, false, false)
        override fun perform(action: PhoneAction): ActionResult { actions += action; writes++; return ActionResult(true, "done") }
        override fun open(packageName: String): ActionResult { opens++; return ActionResult(true, "opened") }
    }

    private fun replace() { tasks.endTask(); tasks.begin() }
    private fun handoffCall() = core.call(PhoneToolCatalog.HANDOFF, mapOf("reason" to "User input"))
    private fun tapCall() = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1))
    @After fun close() = core.worker.shutdown()

    @Test fun currentHandoffContinuesAndReadsTheCurrentScreen() {
        assertFalse(handoffCall().isError)
        assertEquals(1, asked)
        assertEquals(1, main.reads)
    }

    @Test fun replacedTaskCannotContinueOldHandoffOrReadItsSuccessor() {
        handoff = { replace(); HandoffResult.CONTINUE }
        assertTrue(handoffCall().isError)
        assertEquals(0, main.reads)
        assertTrue(tasks.isActive)
    }

    @Test fun oldHandoffStopCannotStopItsSuccessor() {
        handoff = { replace(); HandoffResult.STOP }
        assertTrue(handoffCall().isError)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun replacementDuringBeforeHandoffCannotAskUnderNewTask() {
        beforeHandoff = ::replace
        assertTrue(handoffCall().isError)
        assertEquals(0, asked)
    }

    @Test fun lateConfirmationCannotWriteIntoSuccessor() {
        confirm = { replace(); Decision.ALLOW_ONCE }
        assertTrue(tapCall().isError)
        assertEquals(1, asked)
        assertEquals(0, main.writes)
        assertTrue(tasks.isActive)
    }

    @Test fun lateBackgroundMoveConfirmationCannotMoveApplication() {
        confirm = { replace(); Decision.ALLOW_ONCE }
        assertTrue(core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true)).isError)
        assertEquals(1, asked)
        assertEquals(0, background.opens)
        assertTrue(tasks.isActive)
    }

    @Test fun currentConfirmedWriteStillExecutesExactlyOnce() {
        assertFalse(tapCall().isError)
        assertEquals(1, asked)
        assertEquals(1, main.writes)
    }

    @Test fun missingTapXYObservationNamesTheActualRequiredParameter() {
        val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("x" to 1, "y" to 2))
        assertTrue(result.isError)
        assertEquals("缺少 observation（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun screenIsNotAnAliasForTapXYObservation() {
        val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("screen" to "s1", "x" to 1, "y" to 2))
        assertTrue(result.isError)
        assertEquals("缺少 observation（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun otherRequiredScreenArgumentsKeepTheirExistingName() {
        for (tool in listOf(PhoneToolCatalog.TAP, PhoneToolCatalog.TYPE, PhoneToolCatalog.SCROLL, PhoneToolCatalog.COLLECT)) {
            val result = core.call(tool, mapOf("observation" to "s1"))
            assertTrue(result.isError)
            assertEquals("缺少 screen（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        }
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun validObservationKeepsScreenRoutingCoordinatesAndConfirmation() {
        for ((sid, driver) in listOf("s1" to main, "b1" to background)) {
            val before = asked
            val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("observation" to sid, "x" to 11, "y" to 22))
            assertFalse(result.isError)
            assertEquals(before + 1, asked)
            assertEquals(listOf(PhoneAction.TapXY(sid, 11, 22)), driver.actions)
            assertEquals(1, driver.writes)
        }
    }
}
