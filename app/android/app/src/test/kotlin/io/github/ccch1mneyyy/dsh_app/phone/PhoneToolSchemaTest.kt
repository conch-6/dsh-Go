package io.github.ccch1mneyyy.dsh_app.phone

import java.time.ZoneId
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Actual Core parsing/gating; only Android device operations are recorded by fixtures. */
class PhoneToolSchemaTest {
    private val intents = mutableListOf<IntentSpec>()
    private val actions = mutableListOf<PhoneAction>()
    private val pages = mutableListOf<Int>()
    private var confirmations = 0
    private val driver = object : PhoneDriver {
        override val screen = PhoneScreen.MAIN
        override fun availability() = Availability(true)
        override fun foregroundPackage() = "example.app"
        override fun observe(detail: Boolean, image: Boolean) = ScreenSnapshot("s1", "Example", "Example", "example.app")
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult {
            pages += maxPages
            return CollectResult(emptyList(), 0, "done", null)
        }
        override fun target(screenId: String, elementId: Int): TargetInfo? = error("unexpected target")
        override fun perform(action: PhoneAction): ActionResult { actions += action; return ActionResult(true, "done") }
        override fun open(packageName: String): ActionResult = error("unexpected open")
    }
    private val core = PhoneCore(object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = PhonePolicies()
        override fun isLocked() = false
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("Asia/Shanghai")
        override fun notifyFix(kind: String) {}
        override fun sleep(ms: Long) {}
        override fun driver(screen: PhoneScreen) = if (screen == PhoneScreen.MAIN) driver else null
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest): Decision { confirmations++; return Decision.ALLOW_ONCE }
            override fun handoff(reason: String, timeoutMs: Long): HandoffResult = error("unexpected handoff")
            override fun status(text: String?) {}
        }
        override fun system() = object : SystemApi {
            override fun apps() = emptyList<AppEntry>()
            override fun isInstalled(pkg: String) = false
            override fun launch(app: AppEntry): SysResult = error("unexpected launch")
            override fun urlTarget(url: String): UrlTarget = error("unexpected URL")
            override fun openUrl(url: String, target: UrlTarget): SysResult = error("unexpected URL")
            override fun intent(spec: IntentSpec, shareTo: AppEntry?): SysResult { intents += spec; return SysResult(true, "done") }
            override fun notify(title: String, text: String): SysResult = error("unexpected notification")
            override fun clipboardSet(text: String): SysResult = error("unexpected clipboard")
            override fun clipboardGet(): SysResult = error("unexpected clipboard")
        }
    }, PhoneTasks(), ActionLog())

    @After fun close() = core.worker.shutdown()

    @Test fun sdkSchemaKeepsIntegerFieldsAndMovesBoundsIntoDescriptions() {
        val json = Json.write(PhoneToolCatalog.listJson())
        assertFalse(json.contains("\"minimum\""))
        assertFalse(json.contains("\"maximum\""))
        assertEquals(13, PhoneToolCatalog.tools.size)
        val tap = PhoneToolCatalog.tools.single { it.name == PhoneToolCatalog.TAP_XY }
        assertEquals(listOf("observation", "x", "y"), tap.required)
        assertEquals(setOf("observation", "x", "y"), tap.properties.keys)
        for (key in listOf("x", "y")) {
            val field = tap.properties[key] as Map<*, *>
            assertEquals("integer", field["type"])
            assertTrue((field["description"] as String).contains("从 0 开始"))
        }
        val collect = PhoneToolCatalog.tools.single { it.name == PhoneToolCatalog.COLLECT }
        val count = collect.properties["max_pages"] as Map<*, *>
        assertEquals("integer", count["type"])
        assertTrue((count["description"] as String).contains("1–30"))
        val intent = PhoneToolCatalog.tools.single { it.name == PhoneToolCatalog.INTENT }
        val days = intent.properties["days"] as Map<*, *>
        assertEquals(mapOf("type" to "integer"), days["items"])
        assertTrue((days["description"] as String).contains("1=周一 … 7=周日"))
    }

    @Test fun alarmTimeAndWeekdayBoundsStillRejectBeforeSystemDispatch() {
        for (args in listOf(
            mapOf("hour" to -1), mapOf("hour" to 24),
            mapOf("hour" to 1, "minute" to -1), mapOf("hour" to 1, "minute" to 60),
            mapOf("hour" to 1, "days" to listOf(0)), mapOf("hour" to 1, "days" to listOf(8)),
        )) assertTrue(core.call(PhoneToolCatalog.INTENT, args + ("kind" to "alarm")).isError)
        assertTrue(intents.isEmpty())
        assertFalse(core.call(PhoneToolCatalog.INTENT, mapOf("kind" to "alarm", "hour" to 0, "minute" to 0, "days" to listOf(7, 1, 7))).isError)
        assertFalse(core.call(PhoneToolCatalog.INTENT, mapOf("kind" to "alarm", "hour" to 23, "minute" to 59)).isError)
        assertEquals(listOf(IntentSpec.Alarm(0, 0, null, listOf(1, 7)), IntentSpec.Alarm(23, 59, null, emptyList())), intents)
    }

    @Test fun timerBoundsStillRejectAndAcceptBothEndpoints() {
        for (seconds in listOf(0, 86401)) {
            assertTrue(core.call(PhoneToolCatalog.INTENT, mapOf("kind" to "timer", "seconds" to seconds)).isError)
        }
        assertTrue(intents.isEmpty())
        for (seconds in listOf(1, 86400)) {
            assertFalse(core.call(PhoneToolCatalog.INTENT, mapOf("kind" to "timer", "seconds" to seconds)).isError)
        }
        assertEquals(listOf(IntentSpec.Timer(1, null), IntentSpec.Timer(86400, null)), intents)
    }

    @Test fun collectKeepsDefaultAndClampsInsteadOfWideningItsBudget() {
        val args = mapOf("screen" to "s1", "list" to 1)
        assertFalse(core.call(PhoneToolCatalog.COLLECT, args).isError)
        for (count in listOf(0, 1, 30, 31)) {
            assertFalse(core.call(PhoneToolCatalog.COLLECT, args + ("max_pages" to count)).isError)
        }
        assertEquals(listOf(10, 1, 1, 30, 30), pages)
    }

    @Test fun tapXYKeepsNonnegativeCoordinatesAndUserConfirmation() {
        for ((x, y) in listOf(-1 to 0, 0 to -1)) {
            assertTrue(core.call(PhoneToolCatalog.TAP_XY, mapOf("observation" to "s1", "x" to x, "y" to y)).isError)
        }
        assertTrue(actions.isEmpty())
        assertEquals(0, confirmations)
        assertFalse(core.call(PhoneToolCatalog.TAP_XY, mapOf("observation" to "s1", "x" to 0, "y" to 0)).isError)
        assertEquals(listOf(PhoneAction.TapXY("s1", 0, 0)), actions)
        assertEquals(1, confirmations)
    }
}
