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
    private var beforeHandoff: (PhoneTasks.Owner) -> Unit = {}
    private var asked = 0
    private val statuses = mutableListOf<String?>()
    private var beforeStatus: () -> Unit = {}
    private var deferStatus = false
    private val queuedStatuses = mutableListOf<() -> Unit>()
    private var lookup: () -> Unit = {}
    private var beforeResolve: () -> Unit = {}
    private var freshApp: Either<String, AppEntry> = Either.Right(AppEntry("Example", PhoneAppIdentity("example.app", 10123)))
    private var prepareSystem: () -> Unit = {}
    private var afterStart: () -> Unit = {}
    private var settle: () -> Unit = {}
    private var launchResult = SysResult(true, "launched")
    private var preparedTarget: SystemTarget = SystemTarget.Known(AppEntry("Example", PhoneAppIdentity("example.app", 10123)))
    private var preparedPlan: SystemLaunch? = null
    private var startedPlan: SystemLaunch? = null
    private var policies = PhonePolicies()
    private var launches = 0
    private var urls = 0
    private var intents = 0
    private val main = Driver(PhoneScreen.MAIN)
    private val background = Driver(PhoneScreen.BACKGROUND)
    private val core = PhoneCore(object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = policies
        override fun isLocked() = false
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest): Decision { asked++; return confirm() }
            override fun handoff(reason: String, timeoutMs: Long): HandoffResult { asked++; return handoff() }
            override fun status(text: String?) { statuses += text }
            override fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean) {
                beforeStatus()
                val apply = { if (ifCurrent {}) statuses += text; Unit }
                if (deferStatus) queuedStatuses += apply else apply()
            }
        }
        override fun driver(screen: PhoneScreen) = if (screen == PhoneScreen.MAIN) main else background
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun beforeHandoff(screen: PhoneScreen, owner: PhoneTasks.Owner): String? { beforeHandoff(owner); return null }
        override fun sleep(ms: Long) { settle() }
        override fun system() = object : SystemApi {
            override fun apps(): List<AppEntry> { lookup(); return listOf(AppEntry("Example", PhoneAppIdentity("example.app", 10123))) }
            override fun isInstalled(pkg: String) = true
            override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> {
                beforeResolve()
                return when (val resolved = freshApp) {
                    is Either.Left -> resolved
                    is Either.Right -> Either.Right(TestSystemLaunch(SystemTarget.Known(resolved.value)).also { preparedPlan = it })
                }
            }
            override fun prepareUrl(url: String): Either<String, SystemLaunch> {
                lookup()
                return Either.Right(TestSystemLaunch(preparedTarget, "url").also { preparedPlan = it })
            }
            override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> =
                Either.Right(TestSystemLaunch(preparedTarget, "intent", spec).also { preparedPlan = it })
            override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult {
                commit(dispatch)
                startedPlan = plan
                val fake = plan as TestSystemLaunch
                when (fake.kind) { "app" -> launches++; "url" -> urls++; "intent" -> intents++ }
                afterStart()
                val result = if (fake.kind == "app") launchResult else SysResult(true, "attempted")
                return SysResult(result.ok, result.message, plan.target)
            }
            override fun notify(title: String, text: String) = error("unexpected notification")
            override fun clipboardSet(text: String) = error("unexpected clipboard")
            override fun clipboardGet() = error("unexpected clipboard")
        }
    }, tasks, ActionLog())

    private class Driver(override val screen: PhoneScreen) : PhoneDriver {
        var reads = 0
        var writes = 0
        var opens = 0
        val openedTargets = mutableListOf<PhoneAppIdentity>()
        var observing: () -> Unit = {}
        var observedText = "Example"
        var observedPackage: String? = "example.app"
        var observedImage: ByteArray? = null
        var collects = 0
        var collecting: () -> Unit = {}
        var collectScreen = true
        val actions = mutableListOf<PhoneAction>()
        override fun availability() = Availability(true)
        override fun foregroundPackage() = "example.app"
        override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
            reads++
            observing()
            return ScreenSnapshot("${screen.prefix}1", observedText, "Example", observedPackage, image = observedImage)
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?): CollectResult {
            collects++
            collecting()
            val snapshot = if (collectScreen) ScreenSnapshot("${screen.prefix}2", "late collected screen",
                "Example", "example.app", image = byteArrayOf(1, 2, 3), imageMime = "image/png") else null
            return CollectResult(listOf("late collected item"), 1, "pageLimit", snapshot)
        }
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId,
            "按钮", "发送", "example.app", "Example", false, false, false)
        override fun perform(action: PhoneAction): ActionResult { actions += action; writes++; return ActionResult(true, "done") }
        override fun open(target: PhoneAppIdentity): ActionResult { openedTargets += target; opens++; return ActionResult(true, "opened") }
    }

    // Models the mandatory SystemApi ticket contract, not Android PM or Binder execution.
    private fun commit(dispatch: PhoneTasks.SystemDispatch) {
        prepareSystem()
        if (!dispatch.commitStart()) throw InterruptedException(PhoneTasks.STOPPED_MESSAGE)
    }

    private fun replace() { tasks.endTask(); tasks.begin() }
    private fun handoffCall() = core.call(PhoneToolCatalog.HANDOFF, mapOf("reason" to "User input"))
    private fun tapCall() = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1))
    @After fun close() = core.worker.shutdown()

    private fun openApp() = core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app"))
    private fun openUrl() = core.call(PhoneToolCatalog.OPEN, mapOf("url" to "https://example.com"))
    private fun shareIntent() = core.call(PhoneToolCatalog.INTENT,
        mapOf("kind" to "share", "app" to "example.app", "text" to "example"))

    private fun collectCall(screen: String) = core.call(PhoneToolCatalog.COLLECT,
        mapOf("screen" to screen, "list" to 1, "max_pages" to 3))

    private fun assertCollectStopped(result: ToolOutput) {
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertFalse(result.text.contains("late collected item"))
        assertFalse(result.text.contains("late collected screen"))
        assertNull(result.image)
        assertEquals("stopped", core.log.last()?.decision)
    }

    @Test fun backgroundOpenUsesFreshIdentityBeforeApprovalAndNeverEmitsUid() {
        val identity = PhoneAppIdentity("example.app", 1010123)
        freshApp = Either.Right(AppEntry("Fresh label", identity))
        var resolved = false
        beforeResolve = { resolved = true }
        confirm = { assertTrue(resolved); Decision.ALLOW_ONCE }
        val output = core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true))
        assertFalse(output.text, output.isError)
        assertEquals(listOf(identity), background.openedTargets)
        assertFalse(output.text.contains(identity.uid.toString()))
    }

    @Test fun unavailableFreshIdentityNeverFallsBackToTheCachedApp() {
        freshApp = Either.Left("identity unavailable")
        val output = core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true))
        assertTrue(output.isError)
        assertEquals(0, background.opens)
        assertEquals(0, asked)
    }

    @Test fun stopDuringNativeIdentityRefreshCannotDispatchTheOldScope() {
        beforeResolve = { tasks.stop("stop during PM") }
        assertTrue(core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true)).isError)
        assertEquals(0, background.opens)
    }

    @Test fun aStopDuringCollectDiscardsItsPartialItemsAndScreen() {
        background.collecting = { tasks.stop("stopped while collecting") }
        assertCollectStopped(collectCall("b1"))
        assertEquals(1, background.collects)
        assertTrue(tasks.isStopped())
    }

    @Test fun aReplacedCollectCannotPublishItsContentToTheSuccessor() {
        main.collecting = { replace(); tasks.setApp("successor") }
        assertCollectStopped(collectCall("s1"))
        assertEquals(1, main.collects)
        assertEquals("successor", tasks.snapshot().app)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun clearingAStopDoesNotReviveTheOldCollectResult() {
        background.collecting = { tasks.stop("stop"); tasks.clearStop(); tasks.begin() }
        assertCollectStopped(collectCall("b1"))
        assertEquals(1, background.collects)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun aCurrentCollectKeepsItsItemsAndOptionalScreen() {
        val mainResult = collectCall("s1")
        assertFalse(mainResult.text, mainResult.isError)
        assertTrue(mainResult.text.contains("late collected item"))
        assertTrue(mainResult.text.contains("late collected screen"))
        assertArrayEquals(byteArrayOf(1, 2, 3), mainResult.image)
        assertEquals("ok", core.log.last()?.decision)
        background.collectScreen = false
        val backgroundResult = collectCall("b1")
        assertFalse(backgroundResult.text, backgroundResult.isError)
        assertTrue(backgroundResult.text.contains("late collected item"))
        assertNull(backgroundResult.image)
        assertEquals(1, main.collects)
        assertEquals(1, background.collects)
    }

    @Test fun replacedTaskCannotLaunchAnApplicationAfterLookupReturns() {
        lookup = ::replace
        val result = openApp()
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertEquals(0, launches)
        assertTrue(tasks.isActive)
    }

    @Test fun clearingAStopDoesNotLetTheOldUrlLookupLaunchUnderANewTask() {
        lookup = { tasks.stop("stop"); tasks.clearStop(); tasks.begin() }
        val result = openUrl()
        assertTrue(result.text, result.isError)
        assertEquals(0, urls)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun aStopDuringAppLookupPreventsTheIntentDispatch() {
        lookup = { tasks.stop("stop") }
        val result = shareIntent()
        assertTrue(result.text, result.isError)
        assertEquals(0, intents)
        assertTrue(tasks.isStopped())
    }

    @Test fun anInterruptedLookupCannotDispatchEvenWhileItsOwnerIsCurrent() {
        lookup = { Thread.currentThread().interrupt() }
        val result = shareIntent()
        assertTrue(result.text, result.isError)
        assertEquals(0, intents)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun originalOwnerReachesAllThreeFinalSystemEntries() {
        prepareSystem = ::replace
        assertTrue(openApp().isError)
        assertTrue(openUrl().isError)
        assertTrue(shareIntent().isError)
        assertEquals(0, launches + urls + intents)
    }

    @Test fun aCommittedLateStartCannotRenameOrReadTheSuccessor() {
        afterStart = { replace(); tasks.setApp("successor") }
        assertTrue(openApp().isError)
        assertEquals(1, launches)
        assertEquals("successor", tasks.snapshot().app)
        assertEquals(0, main.reads)
    }

    @Test fun successfulSystemActionsPublishControlStatusBeforeTheirObservation() {
        main.observing = { assertTrue("Control status must be published before post-launch observation", statuses.any { !it.isNullOrBlank() }) }
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            statuses.clear()
            assertFalse(call().isError)
            assertEquals(1, statuses.size)
            assertFalse(statuses.single()!!.contains("example.app"))
            assertFalse(statuses.single()!!.contains("https://"))
        }
        assertEquals(3, main.reads)
    }

    @Test fun aFailedSystemLaunchDoesNotPublishAnActiveControl() {
        launchResult = SysResult(false, "rejected")
        assertTrue(openApp().isError)
        assertTrue(statuses.isEmpty())
        assertEquals(0, main.reads)
    }

    @Test fun listingAppsDoesNotCreateAScreenControl() {
        assertFalse(core.call(PhoneToolCatalog.APPS, emptyMap()).isError)
        assertTrue(statuses.isEmpty())
        assertEquals(0, main.reads)
    }

    @Test fun stoppingAtTheStatusBoundaryCannotPublishOrReadForTheOldOwner() {
        beforeStatus = { tasks.stop("stop before status publication") }
        val result = openApp()
        assertTrue(result.isError)
        assertEquals(1, launches) // The already-returned system effect is not retracted.
        assertEquals(0, main.reads)
        assertTrue(statuses.isEmpty())
    }

    @Test fun delayedStatusIsRejectedAfterStopOrReplacementButCurrentStatusApplies() {
        deferStatus = true
        assertFalse(openApp().isError)
        val stopped = queuedStatuses.removeAt(0)
        tasks.stop("stop before UI application")
        stopped()
        assertTrue(statuses.isEmpty())
        tasks.clearStop()

        assertFalse(openApp().isError)
        val replaced = queuedStatuses.removeAt(0)
        replace()
        replaced()
        assertTrue(statuses.isEmpty())

        assertFalse(openApp().isError)
        queuedStatuses.removeAt(0)()
        assertEquals(1, statuses.size)
    }

    @Test fun currentSystemLaunchesStillDispatchExactlyOnce() {
        assertFalse(openApp().isError)
        assertFalse(openUrl().isError)
        assertFalse(shareIntent().isError)
        assertEquals(1, launches)
        assertEquals(1, urls)
        assertEquals(1, intents)
    }

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
        beforeHandoff = { replace() }
        assertTrue(handoffCall().isError)
        assertEquals(0, asked)
    }

    @Test fun handoffCleanupReceivesTheOriginalOwnerEvenWhenTheTaskIsReplacedInsideTheHook() {
        val original = (tasks.begin() as PhoneTasks.Begin.Go).owner
        var cleanupOwner: PhoneTasks.Owner? = null
        var successor: PhoneTasks.Owner? = null
        beforeHandoff = { captured ->
            replace()
            successor = tasks.activeOwner()
            cleanupOwner = captured // The real hook does not read the task's new activeOwner.
        }
        assertTrue(handoffCall().isError)
        assertEquals(original.taskId, cleanupOwner!!.taskId)
        assertEquals(original.lifecycle, cleanupOwner!!.lifecycle)
        assertNotEquals(successor!!.taskId, cleanupOwner!!.taskId)
        assertTrue(tasks.isCurrent(successor!!))
        assertEquals(0, asked)
        assertEquals(0, main.reads)
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
    private fun replaceDuringNextBegin() {
        var armed = true
        tasks.addListener { snapshot ->
            if (armed && snapshot.active) {
                armed = false
                tasks.stop("listener replaced the original begin")
                tasks.clearStop()
                tasks.begin()
                tasks.setApp("successor")
            }
        }
    }

    @Test fun beginListenerCannotLendSuccessorOwnerToOldLaunch() {
        replaceDuringNextBegin()
        val result = openApp()
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertEquals(0, launches)
        assertEquals(0, main.reads)
        assertEquals("successor", tasks.snapshot().app)
    }

    @Test fun beginListenerCannotLendSuccessorOwnerToOldWrite() {
        replaceDuringNextBegin()
        val result = tapCall()
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertEquals(0, asked)
        assertEquals(0, main.writes)
        assertEquals("successor", tasks.snapshot().app)
    }

    @Test fun launchObservationStoppedWhileReadingDiscardsOldScreen() {
        main.observedText = "late private screen"
        main.observedImage = byteArrayOf(1, 2, 3)
        main.observing = { tasks.stop("stopped while observing") }
        val result = openApp()
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertFalse(result.text.contains("late private screen"))
        assertTrue(result.text.contains("launched"))
        assertNull(result.image)
        assertEquals("stopped", core.log.last()!!.decision)
        assertTrue(core.log.last()!!.summary.contains("已尝试"))
        assertEquals(1, launches)
        assertEquals(1, main.reads)
    }

    @Test fun lateScreenCannotRenameReplacementTaskOrReturnItsContent() {
        main.observedText = "late private screen"
        main.observing = { replace(); tasks.setApp("successor") }
        val result = core.call(PhoneToolCatalog.SCREEN, emptyMap())
        assertTrue(result.text, result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertFalse(result.text.contains("late private screen"))
        assertEquals("successor", tasks.snapshot().app)
        assertEquals(1, main.reads)
    }

    @Test fun appLabelListenerReplacementPreventsPostLaunchObservation() {
        var armed = true
        tasks.addListener { snapshot ->
            if (armed && snapshot.app == "Example") {
                armed = false
                replace()
                tasks.setApp("successor")
            }
        }
        val result = openApp()
        assertTrue(result.text, result.isError)
        assertEquals(1, launches)
        assertEquals(0, main.reads)
        assertEquals("successor", tasks.snapshot().app)
        assertTrue("The app-label listener retired this owner before status publication", statuses.isEmpty())
    }

    @Test fun stoppingDuringSettlePreservesTheReturnedSystemResultWithoutReading() {
        settle = { tasks.stop("stop during settle") }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertTrue(result.text.contains("launched"))
        assertNull(result.image)
        assertEquals(1, launches)
        assertEquals(0, main.reads)
        assertEquals("stopped", core.log.last()!!.decision)
        assertTrue(core.log.last()!!.summary.contains("已尝试"))
        assertFalse(core.log.last()!!.summary.contains("launched"))
    }

    @Test fun interruptedSettlePreservesTheReturnedSystemResult() {
        settle = { throw InterruptedException("settle interrupted") }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertTrue(result.text.contains("launched"))
        assertEquals(1, launches)
        assertEquals(0, main.reads)
        assertEquals("stopped", core.log.last()!!.decision)
        assertTrue(core.log.last()!!.summary.contains("已尝试"))
    }

    @Test fun aFailedSystemReturnIsPreservedWhenItsOwnerWasReplaced() {
        launchResult = SysResult(false, "platform rejected private payload")
        afterStart = { replace(); tasks.setApp("successor") }
        val result = openApp()
        assertTrue(result.isError)
        assertTrue(result.text.startsWith(PhoneTasks.STOPPED_MESSAGE))
        assertTrue(result.text.contains(launchResult.message))
        assertEquals("successor", tasks.snapshot().app)
        assertEquals(0, main.reads)
        assertEquals(1, launches)
        assertEquals("stopped", core.log.last()!!.decision)
        assertTrue(core.log.last()!!.summary.contains("已尝试"))
        assertFalse(core.log.last()!!.summary.contains("private payload"))
    }

    @Test fun everySystemEntrySubmitsTheExactPreparedObject() {
        for (call in listOf(::openApp, ::openUrl, ::shareIntent)) {
            assertFalse(call().isError)
            assertNotNull(preparedPlan)
            assertSame(preparedPlan, startedPlan)
        }
    }

    @Test fun freshMainAppIdentityIsCheckedInsteadOfTheCachedApp() {
        policies = PhonePolicies(denyPackages = listOf("blocked.handler"))
        freshApp = Either.Right(AppEntry("Handler", PhoneAppIdentity("blocked.handler", 20234)))
        assertTrue(openApp().isError)
        assertEquals(0, launches)
        assertNull(startedPlan)
    }

    @Test fun urlAndFixedIntentCheckTheActualPreparedHandler() {
        policies = PhonePolicies(denyPackages = listOf("blocked.handler"))
        preparedTarget = SystemTarget.Known(AppEntry("Handler", PhoneAppIdentity("blocked.handler", 20234)))
        assertTrue(openUrl().isError)
        assertTrue(core.call(PhoneToolCatalog.INTENT, mapOf("kind" to "settings", "page" to "wifi")).isError)
        assertEquals(0, urls + intents)
        assertNull(startedPlan)
    }

    @Test fun settingsSubjectIsNotUsedAsTheHandlerAndChooserHasNoInventedApp() {
        policies = PhonePolicies(denyPackages = listOf("example.app"))
        preparedTarget = SystemTarget.Known(AppEntry("Settings handler", PhoneAppIdentity("vendor.settings", 1000)))
        assertFalse(core.call(PhoneToolCatalog.INTENT,
            mapOf("kind" to "settings", "page" to "app_notifications", "app" to "example.app")).isError)
        assertEquals(1, intents)
        assertEquals("Settings handler", tasks.snapshot().app)
        replace() // A chooser cannot invent a handler for this new task.
        preparedTarget = SystemTarget.UserChoice
        assertFalse(openUrl().isError)
        assertNull(tasks.snapshot().app)
        assertSame(SystemTarget.UserChoice, startedPlan!!.target)
    }

    @Test fun mismatchedPostObservationIsAttachedWithoutRelabelingOrRetryingThePlan() {
        main.observedPackage = "another.app"
        main.observedText = "ACTUAL_OTHER_SCREEN"
        val result = openApp()
        assertFalse(result.isError)
        assertTrue(result.text.contains("ACTUAL_OTHER_SCREEN"))
        assertTrue(result.text.contains("未确认原处理应用"))
        assertEquals(1, launches)
        assertEquals(1, main.reads)
        assertEquals("example.app", (startedPlan!!.target as SystemTarget.Known).app.packageName)
    }

}
