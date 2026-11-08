package io.github.ccch1mneyyy.dsh_app.phone

import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundResourceJournal
import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Real registry -> real Core -> selected worker. Only device services are synthetic. */
class PhoneTaskSessionsTest {
    private val ids = AtomicLong()
    private val time = AtomicLong(1_000)
    @Volatile private var beforeTaskClock: () -> Unit = {}
    private fun taskClock(): Long { beforeTaskClock(); return time.get() }
    private val worker = SerialWorker("session-test", time::get) { false }
    private val backgroundWorkers = java.util.Collections.synchronizedList(mutableListOf<SerialWorker>())
    private val pool = Executors.newCachedThreadPool()
    @Volatile private var confirm: (ConfirmRequest) -> Decision = { Decision.UNAVAILABLE }
    private val actions = AtomicLong()
    @Volatile private var open: (PhoneAppIdentity) -> ActionResult = { error("unexpected launch") }
    @Volatile private var appEntries = listOf(AppEntry("Example", PhoneAppIdentity("example.app", 10123)))
    @Volatile private var prepareLaunch: (AppEntry) -> SystemLaunch = { TestSystemLaunch(SystemTarget.Known(it)) }
    @Volatile private var launch: (SystemLaunch, PhoneTasks.SystemDispatch) -> SysResult = { _, _ -> error("unexpected launch") }
    @Volatile private var prepareUrl: (String) -> SystemLaunch = { error("unexpected URL") }

    @Volatile private var changed: () -> Unit = {}
    @Volatile private var lookup: () -> Unit = {}
    @Volatile private var observe: () -> Unit = {}
    @Volatile private var cleanup: (Long) -> Unit = {}
    @Volatile private var cleanupDispatch: (() -> Unit) -> Unit = { it() }
    @Volatile private var cancelScope: (PhoneTaskSessions.Task, PhoneTasks.Snapshot) -> Unit = { task, state ->
        if (state.stopped) task.activeWorker?.interruptCurrent(task.tasks)
    }
    private val env = object : PhoneEnv {
        override fun enabled() = true
        override fun policies() = PhonePolicies()
        override fun isLocked() = false
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest) = this@PhoneTaskSessionsTest.confirm(request)
            override fun handoff(reason: String, timeoutMs: Long) = HandoffResult.STOP
            override fun status(text: String?) {}
        }
        override fun driver(screen: PhoneScreen) = object : PhoneDriver {
            override val screen = screen
            override fun availability() = Availability(true)
            override fun foregroundPackage() = "example.app"
            override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot { this@PhoneTaskSessionsTest.observe(); return ScreenSnapshot("${screen.prefix}1", "screen", "Example", "example.app") }
            override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unexpected collect")
            override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId, "button", "Button", "example.app", "Example", false, false, false)
            override fun perform(action: PhoneAction): ActionResult { actions.incrementAndGet(); return ActionResult(true, "done") }
            override fun open(target: PhoneAppIdentity) = this@PhoneTaskSessionsTest.open(target)
        }
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun system() = object : SystemApi {
            override fun apps(): List<AppEntry> { lookup(); return appEntries }
            override fun isInstalled(pkg: String) = true
            override fun prepareLaunch(app: AppEntry): Either<String, SystemLaunch> = Either.Right(this@PhoneTaskSessionsTest.prepareLaunch(app))
            override fun launch(plan: SystemLaunch, dispatch: PhoneTasks.SystemDispatch): SysResult = this@PhoneTaskSessionsTest.launch(plan, dispatch)
            override fun prepareUrl(url: String): Either<String, SystemLaunch> = Either.Right(this@PhoneTaskSessionsTest.prepareUrl(url))
            override fun prepareIntent(spec: IntentSpec, selectedApp: AppEntry?): Either<String, SystemLaunch> = error("unexpected intent")
            override fun notify(title: String, text: String): SysResult = error("unexpected notify")
            override fun clipboardSet(text: String): SysResult = error("unexpected clipboard")
            override fun clipboardGet(): SysResult = error("unexpected clipboard")
        }
    }
    private val legacy = PhoneTasks(clock = ::taskClock, idSource = ids::incrementAndGet)
    private val legacyCore = PhoneCore(env, legacy, ActionLog(), worker)
    private var journalBytes: String? = null
    @Volatile private var journalCommit: (String) -> Boolean = { journalBytes = it; true }
    @Volatile private var recoveryAdmission: () -> String? = { null }
    private val journal = PhoneTaskJournal({ journalBytes }, { journalCommit(it) })
    private val sessions = PhoneTaskSessions(::taskClock, ids::incrementAndGet,
        { tasks, _ -> PhoneCore(env, tasks, ActionLog(), worker) }, legacy, legacyCore, { changed() }, settleResources = { cleanup(it) }, dispatchCleanup = { cleanupDispatch(it) }, cancelScope = { task, state -> cancelScope(task, state) },
        journal = journal, recoveryAdmission = { recoveryAdmission() },
        createBackgroundWorker = { SerialWorker("session-background", time::get) { false }.also { backgroundWorkers += it } })
    private fun admit(session: String?, run: String = "1") = sessions.admit(session?.let { PhoneCaller(it, run, "call", runLifecycle = 1) })
    private fun invoke(session: String?, run: String = "1", tool: String = PhoneToolCatalog.APPS) =
        sessions.run(admit(session, run), tool, emptyMap())
    private fun task(session: String, run: String = "1") = sessions.all().single { it.sessionId == session && it.runId == run }
    private fun end(session: String, run: String = "1") { sessions.admitEnd(session, run)?.let(sessions::settleEnd) }
    @After fun close() { pool.shutdownNow(); worker.shutdown(); backgroundWorkers.toList().forEach { it.shutdown() } }

    private fun journalCount(): Int = journalBytes?.let { ((Json.parse(it) as Map<*, *>)["records"] as List<*>).size } ?: 0

    @Test fun durableMarkMustFinishBeforeAnyPreparationAndStopDuringItCannotAct() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val lookups = AtomicLong()
        lookup = { lookups.incrementAndGet() }
        journalCommit = { bytes -> entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); journalBytes = bytes; true }
        val result = pool.submit<ToolOutput> { sessions.run(admit("A"), PhoneToolCatalog.OPEN, mapOf("app" to "example.app")) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS)); assertEquals(0, lookups.get())
            sessions.stopAll("stop")
            release.countDown(); assertTrue(result.get(5, TimeUnit.SECONDS).isError)
            assertEquals(0, lookups.get()); assertEquals(0, actions.get()); assertEquals(0, journalCount())
        } finally { release.countDown() }
    }

    @Test fun launchRetirementDuringDurableMarkCannotExecuteOnTheNextLaunch() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val lookups = AtomicLong()
        lookup = { lookups.incrementAndGet() }
        journalCommit = { bytes -> entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); journalBytes = bytes; true }
        val result = pool.submit<ToolOutput> { sessions.run(admit("A"), PhoneToolCatalog.OPEN, mapOf("app" to "example.app")) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS)); sessions.retire()
            release.countDown(); assertTrue(result.get(5, TimeUnit.SECONDS).isError)
            assertEquals(0, lookups.get()); assertEquals(0, journalCount())
            assertFalse(invoke("B").isError); assertEquals(1, journalCount())
        } finally { release.countDown() }
    }

    @Test fun interruptedProcessBlocksBeforeBeginUntilTheExactVisibleBatchIsAcknowledged() {
        val old = PhoneTaskJournal({ journalBytes }, { journalBytes = it; true }, "00000000-0000-4000-8000-000000000001")
        assertTrue(old.mark(old.record((PhoneTasks().begin() as PhoneTasks.Begin.Go).owner)))
        val lookups = AtomicLong(); lookup = { lookups.incrementAndGet() }
        val output = invoke(null)
        assertTrue(output.isError); assertEquals(PhoneTaskJournal.INTERRUPTION_MESSAGE, output.text)
        assertEquals(0L, legacy.snapshot().id); assertEquals(0, lookups.get())
        assertTrue(journal.acknowledge(journal.status()["batchToken"] as String))
        assertFalse(invoke(null).isError); assertEquals(1, lookups.get())
    }

    @Test fun failedMarkPreventsPreparationAndRealStorageRetryAllowsTheSameScope() {
        val lookups = AtomicLong(); lookup = { lookups.incrementAndGet() }
        journalCommit = { false }
        assertTrue(sessions.run(admit("A"), PhoneToolCatalog.OPEN, mapOf("app" to "example.app")).isError); assertEquals(0, lookups.get()); assertEquals(0, actions.get())
        journalCommit = { journalBytes = it; true }
        assertTrue(sessions.retryJournalStorage())
        assertFalse(invoke("A").isError); assertEquals(1, journalCount())
        end("A"); assertEquals(0, journalCount())
    }

    @Test fun activeThinkingAndPurePauseKeepOneTokenUntilActualEnd() {
        assertFalse(invoke("A").isError); val original = journalBytes
        val task = task("A"); val owner = task.tasks.activeOwner()!!
        task.tasks.setPausedIfCurrent(owner, true); sessions.settleInactive(task)
        assertEquals(original, journalBytes)
        task.tasks.setPausedIfCurrent(owner, false)
        assertFalse(invoke("A").isError); assertEquals(original, journalBytes)
        end("A"); assertEquals(0, journalCount())
    }

    @Test fun physicalSuccessAndJournalClearFailureRetryNeverRepeatsRelease() {
        val releases = AtomicLong(); cleanup = { releases.incrementAndGet() }
        assertFalse(sessions.run(admit("A"), PhoneToolCatalog.SCREEN, emptyMap()).isError)
        journalCommit = { false }; end("A")
        assertEquals(1, releases.get()); assertFalse(task("A").cleanupFailed)
        assertTrue(task("A").journalFailed); assertEquals(1, journalCount())
        journalCommit = { journalBytes = it; true }
        assertTrue(sessions.retryJournalStorage()); assertEquals(1, releases.get())
        assertEquals(0, journalCount()); assertFalse(task("A").journalFailed)
    }

    @Test fun strictCleanupFailureRetainsJournalUntilTheOriginalResourceRetry() {
        assertFalse(sessions.run(admit("A"), PhoneToolCatalog.SCREEN, emptyMap()).isError)
        cleanup = { error("unconfirmed") }; end("A")
        assertEquals(1, journalCount()); assertTrue(task("A").cleanupFailed)
        assertTrue(sessions.retryJournalStorage()); assertEquals(1, journalCount())
        cleanup = {}; assertTrue(sessions.retryCleanup(task("A").tasks.snapshot().id))
        assertEquals(0, journalCount())
    }

    @Test fun appsOnlyLegacyRolloverAndLaunchRetirementClearOriginalRecords() {
        assertFalse(invoke(null).isError); assertEquals(1, journalCount()); val old = journalBytes
        time.addAndGet(legacy.idleMs + 1)
        assertFalse(invoke(null).isError); assertEquals(1, journalCount()); assertNotEquals(old, journalBytes)
        sessions.retire(); assertEquals(0, journalCount())
        assertFalse(invoke("A").isError); sessions.retire(); assertEquals(0, journalCount())
    }

    @Test fun selfCheckReservationBlocksEvenMetadataWithoutCreatingATask() {
        val before = sessions.all().toList()
        val lease = checkNotNull(sessions.tryReserveSelfCheck())
        assertTrue(sessions.selfCheckCurrent(lease))
        assertNull(sessions.tryReserveSelfCheck())
        assertTrue(invoke("new-session").isError)
        assertTrue(invoke(null).isError)
        assertEquals(before, sessions.all())
        assertFalse(legacy.isActive)
        assertEquals(0L, ids.get())
        assertTrue(sessions.releaseSelfCheck(lease))
        assertFalse(invoke("new-session").isError)
    }

    @Test fun localDiagnosticReadRejectsActiveTasksAndDoesNotCreateItsOwnTask() {
        assertFalse(invoke("A").isError)
        assertNull(sessions.readForSelfCheck(worker, 8_000, 15_000) { error("busy read must not run") })
        end("A")
        val before = sessions.all().toList()
        val idsBefore = ids.get()
        val read = sessions.readForSelfCheck(worker, 8_000, 15_000) { "local screen" }
        assertTrue(read is SerialWorker.Outcome.Done && read.value == "local screen")
        assertEquals(before, sessions.all())
        assertEquals(idsBefore, ids.get())
        val lease = checkNotNull(sessions.tryReserveSelfCheck())
        assertTrue(sessions.releaseSelfCheck(lease))
        val failed = sessions.readForSelfCheck(worker, 8_000, 15_000) { error("system read failed") }
        assertTrue(failed is SerialWorker.Outcome.Failed)
        assertFalse(invoke("B").isError)
    }

    @Test fun localDiagnosticStopSealsTheOriginalReadAndSuppressesLateSuccess() {
        val entered = CountDownLatch(1); val reply = CountDownLatch(1)
        val result = pool.submit<SerialWorker.Outcome<String>?> {
            sessions.readForSelfCheck(worker, 8_000, 15_000) {
                entered.countDown(); check(reply.await(5, TimeUnit.SECONDS)); "late screen"
            }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            sessions.stopAll("stop local read")
            assertNull(sessions.tryReserveSelfCheck())
            assertTrue(invoke("A").isError)
            reply.countDown()
            assertSame(SerialWorker.Outcome.Interrupted, result.get(5, TimeUnit.SECONDS))
            assertFalse(invoke("A").isError)
        } finally { reply.countDown() }
    }

    @Test fun localDiagnosticRetirementKeepsTheOldReadFenceUntilItsBodyReturns() {
        val entered = CountDownLatch(1); val reply = CountDownLatch(1)
        val result = pool.submit<SerialWorker.Outcome<String>?> {
            sessions.readForSelfCheck(worker, 8_000, 15_000) {
                entered.countDown()
                // A committed platform read may still finish after worker retirement.
                while (true) {
                    try { check(reply.await(5, TimeUnit.SECONDS)); break }
                    catch (_: InterruptedException) { }
                }
                "old launch screen"
            }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            sessions.retire()
            assertNull(sessions.tryReserveSelfCheck())
            assertTrue(invoke("new launch").isError)
            reply.countDown()
            assertSame(SerialWorker.Outcome.Interrupted, result.get(5, TimeUnit.SECONDS))
            assertFalse(invoke("new launch").isError)
        } finally { reply.countDown() }
    }

    @Test fun localDiagnosticTimeoutDoesNotReleaseAnAbandonedPhysicalBody() {
        val entered = CountDownLatch(1); val reply = CountDownLatch(1)
        val body = AtomicReference<Thread>()
        val result = pool.submit<SerialWorker.Outcome<String>?> {
            sessions.readForSelfCheck(worker, 8_000, 15_000) {
                body.set(Thread.currentThread()); entered.countDown()
                while (true) {
                    try { check(reply.await(5, TimeUnit.SECONDS)); break }
                    catch (_: InterruptedException) { }
                }
                "late screen"
            }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            time.addAndGet(20_000) // Advance the real worker's clock; do not sleep through its budget.
            val timedOut = result.get(5, TimeUnit.SECONDS)
            assertTrue(timedOut is SerialWorker.Outcome.TimedOut && !timedOut.queued)
            assertNull(sessions.tryReserveSelfCheck())
            assertTrue(invoke("A").isError)
            reply.countDown()
            // This executor was actually abandoned/shut down. Its thread exits only after
            // Callable.finally has delivered the production afterDrained callback.
            body.get().join(5_000)
            assertFalse(body.get().isAlive)
            assertFalse(invoke("A").isError)
        } finally { reply.countDown() }
    }

    @Test fun localDiagnosticStoppedBeforeWorkerClaimNeverReads() {
        val atClock = CountDownLatch(1); val clockReply = CountDownLatch(1)
        val localWorker = SerialWorker("local-read-claim", {
            if (Thread.currentThread().name.startsWith("local-read-claim-")) {
                atClock.countDown(); check(clockReply.await(5, TimeUnit.SECONDS))
            }
            time.get()
        }) { false }
        val reads = AtomicLong()
        val result = pool.submit<SerialWorker.Outcome<Long>?> {
            sessions.readForSelfCheck(localWorker, 8_000, 15_000) { reads.incrementAndGet() }
        }
        try {
            assertTrue(atClock.await(5, TimeUnit.SECONDS))
            sessions.stopAll("stop queued read")
            clockReply.countDown()
            assertSame(SerialWorker.Outcome.Interrupted, result.get(5, TimeUnit.SECONDS))
            assertEquals(0L, reads.get())
            assertFalse(invoke("A").isError)
        } finally { clockReply.countDown(); localWorker.shutdown() }
    }

    @Test fun pendingCallAndActiveThinkingBothExcludeSelfCheck() {
        val pending = admit("A")
        assertNull(sessions.tryReserveSelfCheck())
        assertFalse(sessions.run(pending, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertNull(sessions.tryReserveSelfCheck()) // no worker body, but original task remains active
        end("A")
        val lease = checkNotNull(sessions.tryReserveSelfCheck())
        assertTrue(sessions.releaseSelfCheck(lease))
    }

    @Test fun selfCheckSealAndLaunchRetirementPreserveOriginalCleanupIdentity() {
        val original = checkNotNull(sessions.tryReserveSelfCheck())
        sessions.sealSelfCheck(original)
        assertFalse(sessions.selfCheckCurrent(original))
        assertTrue(invoke("A").isError)
        sessions.retire()
        assertNull(sessions.tryReserveSelfCheck())
        assertTrue(invoke("A").isError)
        assertTrue(sessions.releaseSelfCheck(original)) // old epoch still owns the physical fence
        val next = checkNotNull(sessions.tryReserveSelfCheck())
        assertFalse(sessions.releaseSelfCheck(original))
        sessions.sealSelfCheck(original)
        assertTrue(sessions.selfCheckCurrent(next))
        assertTrue(sessions.releaseSelfCheck(next))
    }

    @Test fun unconfirmedRetiringResourceExcludesSelfCheckUntilActualCleanup() {
        assertFalse(invoke(null, tool = PhoneToolCatalog.SCREEN).isError)
        val oldId = legacy.snapshot().id
        cleanup = { throw IllegalStateException("unconfirmed") }
        sessions.retire()
        assertNull(sessions.tryReserveSelfCheck())
        cleanup = { assertEquals(oldId, it) }
        assertTrue(sessions.retryCleanup(oldId))
        val lease = checkNotNull(sessions.tryReserveSelfCheck())
        assertTrue(sessions.releaseSelfCheck(lease))
    }

    @Test fun scopeCancellationMustFinishBeforeSelfCheckCanReserve() {
        assertFalse(invoke("A").isError)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        cancelScope = { _, _ -> entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) }
        val stopping = pool.submit<Boolean> { sessions.stop(task("A"), "stop") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertNull(sessions.tryReserveSelfCheck())
            release.countDown()
            assertTrue(stopping.get(5, TimeUnit.SECONDS))
            val lease = checkNotNull(sessions.tryReserveSelfCheck())
            assertTrue(sessions.releaseSelfCheck(lease))
        } finally { release.countDown() }
    }

    @Test fun appSnapshotStopStillStopsAnIdleProjectedLegacyTask() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        time.addAndGet(legacy.idleMs + 1)
        val idle = legacy.snapshot()
        assertFalse(idle.active)
        assertTrue(legacy.isActive) // Snapshot projection has not called endLocked yet.
        assertTrue(sessions.stop(record, idle, "App stop"))
        assertTrue(legacy.isStopped())
        assertFalse(legacy.isActive)
    }

    @Test fun delayedLegacyFinishReceiptCannotEndTheSuccessorInTheSameRecord() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        val old = legacy.snapshot()
        legacy.endTask()
        assertFalse(invoke(null).isError)
        val next = checkNotNull(legacy.activeOwner())
        assertNotEquals(old.id, next.taskId)
        assertNull(sessions.finish(record, old))
        assertTrue(legacy.isCurrent(next))
        assertTrue(legacy.isActive)
        assertNotNull(sessions.finish(record, legacy.snapshot()))
        assertFalse(legacy.isActive)
    }

    @Test fun oldInactiveNoticeCannotCancelAnAlreadyReservedSuccessorBeforeBegin() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        legacy.endTask()
        val old = legacy.snapshot()
        val admission = admit(null)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        var cancellations = 0
        cancelScope = { _, _ -> cancellations++ }
        beforeTaskClock = {
            if (Thread.currentThread().name == "reserved-successor") {
                entered.countDown()
                assertTrue(release.await(5, TimeUnit.SECONDS))
            }
        }
        val result = java.util.concurrent.atomic.AtomicReference<ToolOutput>()
        val next = Thread({ result.set(sessions.run(admission, PhoneToolCatalog.APPS, emptyMap())) }, "reserved-successor").apply { start() }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            // begin holds Tasks.lock, but the listener must reject from the registry reservation
            // without waiting for that lock or touching worker/prompt cancellation.
            assertFalse(pool.submit<Boolean> { sessions.onInactive(record, old) }.get(5, TimeUnit.SECONDS))
            assertEquals(0, cancellations)
            beforeTaskClock = {}
            release.countDown(); next.join(5_000)
            assertFalse(next.isAlive)
            assertFalse(checkNotNull(result.get()).isError)
            assertTrue(legacy.isActive)
        } finally { beforeTaskClock = {}; release.countDown(); next.join(5_000) }
    }

    @Test fun staleSelectedOwnerAndInactiveSnapshotCannotStopAResumedScope() {
        assertFalse(invoke("A").isError)
        val record = task("A")
        val oldOwner = checkNotNull(record.tasks.activeOwner())
        assertTrue(sessions.stop(record, oldOwner, "first stop"))
        val stopped = record.tasks.snapshot()
        assertTrue(sessions.resume(record))
        assertFalse(invoke("A").isError)
        val nextOwner = checkNotNull(record.tasks.activeOwner())
        var cancellations = 0
        cancelScope = { _, _ -> cancellations++ }
        assertFalse(sessions.stop(record, oldOwner, "late button"))
        assertFalse(sessions.onInactive(record, stopped))
        assertEquals(0, cancellations)
        assertTrue(record.tasks.isCurrent(nextOwner))
        assertFalse(record.tasks.isStopped())
        assertFalse(invoke("A").isError)
    }

    @Test fun externalScopeCancellationFencesResumeAndLegacyBeginWithoutHoldingRegistryLock() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        cancelScope = { _, _ -> entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) }
        val stopping = pool.submit<Boolean> { sessions.stop(record, "stop") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            // A lock-held callback would prevent this independent registry read from completing.
            assertTrue(pool.submit<Boolean> { sessions.all().contains(record) }.get(5, TimeUnit.SECONDS))
            time.addAndGet(legacy.stopHoldMs + 1)
            assertFalse(sessions.resume(record))
            assertTrue(invoke(null).isError)
            release.countDown()
            assertTrue(stopping.get(5, TimeUnit.SECONDS))
            assertTrue(sessions.resume(record))
            assertFalse(invoke(null).isError)
        } finally { release.countDown() }
    }

    @Test fun launchRetirementCannotExposeLegacyWhileOldScopeCancellationIsOutstanding() {
        assertFalse(invoke(null).isError)
        val record = sessions.all().single { it.sessionId == null }
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        cancelScope = { _, _ -> entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) }
        val stopping = pool.submit<Boolean> { sessions.stop(record, "old launch") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            sessions.retire()
            time.addAndGet(legacy.stopHoldMs + 1)
            assertTrue(invoke(null).isError)
            release.countDown()
            assertTrue(stopping.get(5, TimeUnit.SECONDS))
            assertFalse(invoke(null).isError)
        } finally { release.countDown() }
    }

    @Test fun safetyGateStopInvalidatesAlreadyAdmittedLegacyCallBeyondTheHold() {
        assertFalse(invoke(null).isError)
        val queued = admit(null)
        val owner = checkNotNull(legacy.activeOwner())
        assertTrue(legacy.stopIfCurrent(owner, "gate stopped"))
        time.addAndGet(legacy.stopHoldMs + 1)
        val calls = actions.get()
        var lookedUp = false
        lookup = { lookedUp = true }
        assertTrue(sessions.run(queued, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertFalse(lookedUp)
        assertEquals(calls, actions.get())
        assertFalse(invoke(null).isError)
    }

    @Test fun approvalPauseInterjectionAndLegacyStateDoNotCrossSessions() {
        assertFalse(invoke("A").isError); assertFalse(invoke("B").isError); assertFalse(invoke(null).isError)
        val a = task("A").tasks; val b = task("B").tasks
        a.approve("example.app"); a.waive(); a.interject("A only"); a.setPaused(true)
        assertFalse(b.isApproved("example.app")); assertFalse(b.isWaived); assertFalse(b.isPaused)
        assertTrue(b.drainInterjections().isEmpty()); assertTrue(legacy.drainInterjections().isEmpty())
        assertFalse(legacy.isWaived); assertNotEquals(a.snapshot().id, b.snapshot().id)
        assertNotEquals(a.snapshot().id, legacy.snapshot().id)
        assertSame(task("A").core.worker, task("B").core.worker)
    }

    @Test fun unknownAndDuplicateEndsFenceLateCallsBeforeAnyBodyRuns() {
        var called = false; lookup = { called = true }
        assertNull(sessions.admitEnd("A", "1"))
        assertNull(sessions.admitEnd("A", "1"))
        assertTrue(invoke("A").isError); assertFalse(called)
        assertFalse(invoke("B").isError); assertTrue(called)
    }

    @Test fun endWhileBodyIsPendingIsRememberedUntilTheBodyDrains() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        lookup = {
            entered.countDown()
            var done = false
            while (!done) try { done = release.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
        }
        val running = pool.submit<ToolOutput> { invoke("A") }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val a = task("A")
        try {
            end("A")
            assertTrue(sessions.isBusy(a)); assertNull(a.finished)
            assertTrue(sessions.run(admit("A"), PhoneToolCatalog.APPS, emptyMap()).isError)
        } finally { release.countDown() }
        running.get(5, TimeUnit.SECONDS)
        assertFalse(sessions.isBusy(a)); assertFalse(a.tasks.isActive)
        val receipt = checkNotNull(a.finished)
        assertNotNull(sessions.completed(receipt.taskId, "1", receipt.lifecycle))
        assertNull(sessions.completed(receipt.taskId, "1", receipt.lifecycle))
        assertNull(sessions.admitEnd("A", "1"))
    }

    @Test fun endBeforeQueuedCallCannotStartItAndLaunchRetirementRejectsOldAdmissions() {
        val old = admit("A")
        end("A")
        assertTrue(sessions.run(old, PhoneToolCatalog.APPS, emptyMap()).isError)
        val beforeRetire = admit("B")
        sessions.retire()
        assertTrue(sessions.run(beforeRetire, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertFalse(invoke("A").isError) // ended fences belong to the retired launch only
    }

    @Test fun userStopSurvivesTimeAndLaterTurnsUntilExplicitResume() {
        invoke("A")
        val a = task("A")
        sessions.stop(a, "user")
        time.addAndGet(10 * 60_000)
        assertTrue(invoke("A", "2").isError)
        end("A")
        assertTrue(invoke("A", "3").isError)
        sessions.resume(a)
        assertFalse(invoke("A", "3").isError)
        assertTrue(invoke("A", "1").isError) // explicit resume does not reopen an ended run
    }

    @Test fun newerAdmissionRevokesOldReturnWithoutFinishingTheNewRun() {
        invoke("A")
        val a = task("A")
        end("A")
        val receipt = checkNotNull(a.finished)
        invoke("A", "2")
        end("A")
        assertTrue(task("A", "2").tasks.isActive)
        assertNull(sessions.completed(receipt.taskId, "1", receipt.lifecycle))
    }
    @Test fun anyStillActiveSessionCountsNotJustTheLastOne() {
        assertFalse(sessions.anyActive())
        val queued = admit("C") // Admitted, not begun: it would act under whatever policy it finds.
        assertTrue(sessions.anyActive())
        end("C"); assertTrue(sessions.run(queued, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertFalse(sessions.anyActive())
        assertFalse(invoke("A").isError); assertFalse(invoke("B").isError)
        end("B") // The newest (displayed) task ended; A still runs.
        assertFalse(task("B").tasks.isActive)
        assertTrue(sessions.anyActive())
        end("A")
        assertFalse(sessions.anyActive())
        assertFalse(invoke(null).isError) // The legacy task counts too.
        assertTrue(sessions.anyActive())
        sessions.stopAll("stop")
        assertFalse(sessions.anyActive())
    }

    @Test fun aScreenWaitDoesNotOccupyTheWorkerNeededByItsHolder() {
        assertFalse(invoke("A", tool = PhoneToolCatalog.SCREEN).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.all().any { it.sessionId == "B" && it.waitingScreens.firstOrNull() == PhoneScreen.MAIN }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        // This call must execute while B waits. Placing lease waits inside SerialWorker deadlocks it.
        val a = pool.submit<ToolOutput> { invoke("A") }
        assertFalse(a.get(5, TimeUnit.SECONDS).isError)
        end("A")
        assertFalse(b.get(5, TimeUnit.SECONDS).isError)
    }

    private fun screen(session: String, background: Boolean = false) =
        sessions.run(admit(session), PhoneToolCatalog.SCREEN, mapOf("background" to background))
    private fun openBackground(session: String) = sessions.run(admit(session), PhoneToolCatalog.OPEN,
        mapOf("background" to true, "app" to "example.app"))

    @Test fun compoundOpenWaitsWithoutTakingMainAndThenDispatchesOnce() {
        assertFalse(screen("A", background = true).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "background" }) waiting.countDown() }
        confirm = { Decision.ALLOW_ONCE }
        val launches = AtomicLong()
        open = { launches.incrementAndGet(); ActionResult(true, "opened") }
        val b = pool.submit<ToolOutput> { openBackground("B") }
        try {
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            assertFalse(pool.submit<ToolOutput> { screen("C") }.get(5, TimeUnit.SECONDS).isError)
            assertFalse(invoke("metadata").isError)
            assertTrue(task("metadata").resourcesReleased)
            assertEquals(0L, launches.get())
            end("C"); end("A")
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            assertEquals(1L, launches.get())
        } finally { end("A"); end("C"); end("B") }
    }

    @Test fun compoundOpenOwnsBothScreensBeforeItsDriverRuns() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val mainWait = CountDownLatch(1); val backgroundWait = CountDownLatch(1)
        confirm = { Decision.ALLOW_ONCE }
        open = { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)); ActionResult(true, "opened") }
        val opening = pool.submit<ToolOutput> { openBackground("owner") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            changed = {
                sessions.snapshot().forEach {
                    if (it["sessionId"] == "main" && it["waitingForScreen"] == "main") mainWait.countDown()
                    if (it["sessionId"] == "background" && it["waitingForScreen"] == "background") backgroundWait.countDown()
                }
            }
            val main = pool.submit<ToolOutput> { screen("main") }
            val background = pool.submit<ToolOutput> { screen("background", background = true) }
            assertTrue(mainWait.await(5, TimeUnit.SECONDS))
            assertTrue(backgroundWait.await(5, TimeUnit.SECONDS))
            release.countDown()
            assertFalse(opening.get(5, TimeUnit.SECONDS).isError)
            end("owner")
            assertFalse(main.get(5, TimeUnit.SECONDS).isError)
            assertFalse(background.get(5, TimeUnit.SECONDS).isError)
        } finally { release.countDown(); end("owner"); end("main"); end("background") }
    }

    @Test fun changingBlockerDoesNotRestartTheCompoundThirtySecondBudget() {
        assertFalse(screen("main").isError)
        assertFalse(screen("background", background = true).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "open" && it["waitingForScreen"] == "main" }) waiting.countDown() }
        val result = pool.submit<ToolOutput> { openBackground("open") }
        try {
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(PhoneScreen.MAIN, PhoneScreen.BACKGROUND), task("open").waitingScreens)
            time.addAndGet(30_001)
            end("main") // notify the actual wait; BACKGROUND still belongs to its original task.
            val timedOut = result.get(5, TimeUnit.SECONDS)
            assertTrue(timedOut.isError)
            assertTrue(timedOut.text.contains("30 秒"))
            assertTrue(task("open").resourcesReleased)
            assertTrue(task("open").waitingScreens.isEmpty())
            // The expired compound request did not inherit the just-released MAIN.
            assertFalse(pool.submit<ToolOutput> { screen("next-main") }.get(5, TimeUnit.SECONDS).isError)
        } finally { end("main"); end("background"); end("open"); end("next-main") }
    }

    @Test fun timeoutPreservesTheRequestersPreexistingBackgroundLease() {
        assertFalse(screen("A", background = true).isError)
        val originalId = task("A").resourceTaskId
        assertFalse(screen("B").isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "A" && it["waitingForScreen"] == "main" }) waiting.countDown() }
        val result = pool.submit<ToolOutput> { openBackground("A") }
        try {
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            time.addAndGet(30_001)
            // A metadata run completes and notifies the registry without freeing either screen.
            assertFalse(invoke("wake").isError)
            assertTrue(result.get(5, TimeUnit.SECONDS).text.contains("30 秒"))
            assertFalse(task("A").resourcesReleased)
            assertEquals(originalId, task("A").resourceTaskId)
            val cWaiting = CountDownLatch(1)
            changed = { if (sessions.snapshot().any { it["sessionId"] == "C" && it["waitingForScreen"] == "background" }) cWaiting.countDown() }
            val c = pool.submit<ToolOutput> { screen("C", background = true) }
            assertTrue(cWaiting.await(5, TimeUnit.SECONDS))
            assertFalse(c.isDone)
            end("A")
            assertFalse(c.get(5, TimeUnit.SECONDS).isError)
        } finally { end("A"); end("B"); end("C") }
    }

    @Test fun existingOppositeLeasesStillDetectAWaitCycleWithoutDispatch() {
        assertFalse(screen("A", background = true).isError)
        assertFalse(screen("B").isError)
        val waiting = CountDownLatch(1); val releaseA = CountDownLatch(1)
        val firstWait = java.util.concurrent.atomic.AtomicBoolean(true)
        changed = {
            if (sessions.snapshot().any { it["sessionId"] == "A" && it["waitingForScreen"] == "main" } && firstWait.compareAndSet(true, false)) {
                waiting.countDown()
                assertTrue(releaseA.await(5, TimeUnit.SECONDS))
            }
        }
        val a = pool.submit<ToolOutput> { openBackground("A") }
        try {
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            val rejected = pool.submit<ToolOutput> { openBackground("B") }.get(5, TimeUnit.SECONDS)
            assertTrue(rejected.isError)
            assertTrue(rejected.text.contains("等待环"))
            assertFalse(task("A").resourcesReleased)
            assertFalse(task("B").resourcesReleased)
            assertTrue(task("B").waitingScreens.isEmpty())
            assertEquals(0L, actions.get())
            releaseA.countDown()
            assertTrue(sessions.stop(task("A"), "test stop"))
            assertTrue(a.get(5, TimeUnit.SECONDS).isError)
        } finally { releaseA.countDown(); end("A"); end("B") }
    }

    @Test fun stopRemovesCompoundWaitWithoutReleasingAnotherTasksScreen() {
        assertFalse(screen("holder", background = true).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "waiter" && it["waitingForScreen"] == "background" }) waiting.countDown() }
        val pending = pool.submit<ToolOutput> { openBackground("waiter") }
        try {
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            assertTrue(sessions.stop(task("waiter"), "test stop"))
            assertTrue(pending.get(5, TimeUnit.SECONDS).isError)
            assertTrue(task("waiter").waitingScreens.isEmpty())
            assertTrue(task("waiter").resourcesReleased)
            assertFalse(task("holder").resourcesReleased)
            assertFalse(pool.submit<ToolOutput> { screen("main") }.get(5, TimeUnit.SECONDS).isError)
        } finally { end("holder"); end("waiter"); end("main") }
    }

    @Test fun anOldRunEndCannotInterruptAnotherSessionsActiveWorker() {
        invoke("A")
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        lookup = { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
        val b = pool.submit<ToolOutput> { invoke("B") }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        try { end("A") } finally { release.countDown() }
        assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        assertTrue(task("B").tasks.isActive)
    }

    @Test fun firstClassificationIsImmutableAndOldCompletedCannotUpgradeAnotherRun() {
        invoke("A")
        end("A")
        assertEquals("unknown", task("A").completion)
        assertNull(sessions.admitEnd("A", "1", "completed"))
        assertEquals("unknown", task("A").completion)
        invoke("A", "2")
        sessions.admitEnd("A", "2", "other")?.let(sessions::settleEnd)
        assertNull(sessions.admitEnd("A", "2", "completed"))
        assertEquals("other", task("A", "2").completion)
        sessions.admitEnd("unknown-first", "1", "other")
        assertNull(sessions.admitEnd("unknown-first", "1", "completed"))
        assertTrue(invoke("unknown-first").isError)
        assertFalse(sessions.all().any { it.sessionId == "unknown-first" })
    }

    @Test fun backgroundCoordinatesWaitOnObservationScreenAndDoNotClaimMain() {
        assertFalse(sessions.run(admit("A"), PhoneToolCatalog.SCREEN, mapOf("background" to true)).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.all().any { it.sessionId == "B" && it.waitingScreens.firstOrNull() == PhoneScreen.BACKGROUND }) waiting.countDown() }
        val coordinate = pool.submit<ToolOutput> {
            sessions.run(admit("B"), PhoneToolCatalog.TAP_XY, mapOf("observation" to "b1", "x" to 1, "y" to 1))
        }
        try {
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            val main = pool.submit<ToolOutput> { invoke("C", tool = PhoneToolCatalog.SCREEN) }
            assertFalse(main.get(5, TimeUnit.SECONDS).isError)
            assertFalse(invoke("A").isError)
        } finally { end("A") }
        // No fake approval authority was supplied, so the real Core must still refuse the write.
        assertTrue(coordinate.get(5, TimeUnit.SECONDS).isError)
    }

    @Test fun invalidCoordinateObservationDoesNotAcquireAFallbackScreen() {
        assertTrue(sessions.run(admit("bad"), PhoneToolCatalog.TAP_XY, mapOf("screen" to "b1", "x" to 1, "y" to 1)).isError)
        val main = pool.submit<ToolOutput> { invoke("C", tool = PhoneToolCatalog.SCREEN) }
        assertFalse(main.get(5, TimeUnit.SECONDS).isError)
        assertTrue(sessions.run(admit("bad2"), PhoneToolCatalog.TAP_XY, mapOf("observation" to "wrong", "x" to 1, "y" to 1)).isError)
    }

    @Test fun olderCallerAttributionKeepsLegacyLifecycleAndNeverAdoptsAModernTask() {
        invoke("modern")
        val modern = task("modern")
        val b1 = sessions.admit(PhoneCaller("old-runtime", "old:1", "call"))
        assertFalse(sessions.run(b1, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertTrue(legacy.isActive)
        assertFalse(sessions.all().any { it.sessionId == "old-runtime" })
        assertNotEquals(legacy.snapshot().id, modern.tasks.snapshot().id)
        sessions.finish(sessions.all().single { it.sessionId == null })
        assertTrue(modern.tasks.isActive)
    }

    @Test fun timedOutRpcDoesNotPublishFinishedUntilTheAbandonedBodyActuallyExits() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val finished = CountDownLatch(1)
        lookup = {
            entered.countDown()
            var done = false
            while (!done) try { done = release.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
        }
        val running = pool.submit<ToolOutput> { invoke("A") }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val a = task("A")
        changed = { if (a.finished != null) finished.countDown() }
        try {
            time.addAndGet(20_000) // actual Core APPS budget is 15 seconds; no wall-clock sleep
            assertTrue(running.get(5, TimeUnit.SECONDS).isError)
            assertEquals(0, a.pending)
            assertTrue(a.running)
            end("A")
            assertEquals(1, journalCount())
            assertNull(a.finished)
            assertTrue(sessions.isBusy(a))
            val wire = sessions.snapshot().single { it["sessionId"] == "A" }
            assertEquals(true, wire["draining"]); assertEquals(true, wire["finishing"])
        } finally { release.countDown() }
        assertTrue(finished.await(5, TimeUnit.SECONDS))
        assertEquals(0, journalCount())
        assertFalse(sessions.isBusy(a)); assertFalse(a.tasks.isActive)
        lookup = {}
        assertFalse(invoke("B").isError) // shared successor worker remains usable
    }

    @Test fun legacyKeepsItsOldQuietStopHoldRatherThanTheModernStickyFence() {
        invoke(null)
        val old = sessions.all().single { it.sessionId == null }
        sessions.stop(old, "user")
        time.addAndGet(20_000)
        assertTrue(invoke(null).isError) // a retry extends the original PhoneTasks hold
        time.addAndGet(20_000)
        assertTrue(invoke(null).isError)
        time.addAndGet(31_000)
        assertFalse(invoke(null).isError)
    }

    @Test fun actualSafetyGateDoesNotReuseAnotherSessionsAppApproval() {
        val asked = mutableListOf<Long>()
        confirm = { request -> asked += checkNotNull(request.owner).taskId; Decision.ALLOW_APP_FOR_TASK }
        assertFalse(sessions.run(admit("A"), PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1)).isError)
        assertTrue(task("A").tasks.isApproved("example.app"))
        confirm = { request -> asked += checkNotNull(request.owner).taskId; Decision.DENY }
        assertTrue(sessions.run(admit("B"), PhoneToolCatalog.TAP, mapOf("screen" to "b1", "id" to 1)).isError)
        assertEquals(listOf(task("A").tasks.snapshot().id, task("B").tasks.snapshot().id), asked)
        assertFalse(task("B").tasks.isApproved("example.app")); assertEquals(1L, actions.get())
    }

    @Test fun lateApprovalForStoppedAIsNotAppliedToAOrB() {
        invoke("B")
        confirm = { request ->
            val a = task("A")
            assertEquals(a.tasks.snapshot().id, checkNotNull(request.owner).taskId)
            sessions.stop(a, "stop while confirmation pending")
            Decision.ALLOW_ALL_FOR_TASK
        }
        assertTrue(sessions.run(admit("A"), PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1)).isError)
        assertEquals(0L, actions.get())
        assertFalse(task("A").tasks.isWaived); assertFalse(task("B").tasks.isWaived)
        assertTrue(task("B").tasks.isActive)
    }

    @Test fun unionBudgetRejectsNewRecordsWithoutEvictingEndedFencesOrBlockingExistingEnds() {
        val bounded = PhoneTaskSessions(time::get, ids::incrementAndGet,
            { state, _ -> PhoneCore(env, state, ActionLog(), worker) }, legacy, legacyCore, maxRuns = 2)
        fun input(session: String) = PhoneCaller(session, "1", "call", runLifecycle = 1)
        assertFalse(bounded.run(bounded.admit(input("A")), PhoneToolCatalog.APPS, emptyMap()).isError)
        assertNull(bounded.admitEnd("ended-before-call", "1"))
        assertTrue(bounded.run(bounded.admit(input("new")), PhoneToolCatalog.APPS, emptyMap()).isError)
        assertTrue(bounded.run(bounded.admit(input("ended-before-call")), PhoneToolCatalog.APPS, emptyMap()).isError)
        assertEquals(2, bounded.all().size) // legacy + A; fenced run never allocates a Core
        try { bounded.admitEnd("unknown-full", "1"); fail("must not ACK an unrecorded end") }
        catch (_: PhoneTaskSessions.CapacityExceeded) { }
        bounded.admitEnd("A", "1", "completed")?.let(bounded::settleEnd)
        assertFalse(bounded.all().single { it.sessionId == "A" }.tasks.isActive)
        assertNull(bounded.admitEnd("ended-before-call", "1", "completed"))
        assertTrue(bounded.run(bounded.admit(input("A")), PhoneToolCatalog.APPS, emptyMap()).isError)
        bounded.retire()
        assertFalse(bounded.run(bounded.admit(input("new")), PhoneToolCatalog.APPS, emptyMap()).isError)
    }

    @Test fun physicalCleanupHoldsBothLeasesAndDoesNotHoldRegistryLock() {
        assertFalse(invoke("A", tool = PhoneToolCatalog.SCREEN).isError)
        assertFalse(sessions.run(admit("A"), PhoneToolCatalog.SCREEN, mapOf("background" to true)).isError)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val waiting = CountDownLatch(1)
        cleanup = { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) }
        val ending = pool.submit { end("A") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertNull(task("A").finished)
            changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "main" }) waiting.countDown() }
            val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS)) // snapshot/admit work while cleanup is blocked
            assertFalse(b.isDone)
            assertFalse(sessions.resume(task("A")))
            release.countDown(); ending.get(5, TimeUnit.SECONDS)
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            assertNotNull(task("A").finished)
        } finally { release.countDown() }
    }

    @Test fun cleanupFailureKeepsPhysicalFenceUntilExplicitRetryAndPreservesTheOriginalReceipt() {
        invoke("A", tool = PhoneToolCatalog.SCREEN)
        cleanup = { throw IllegalStateException("device release not confirmed") }
        end("A")
        val a = task("A")
        assertNull(a.finished); assertTrue(a.cleanupFailed); assertTrue(sessions.isBusy(a))
        assertFalse(sessions.resume(a))
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "main" }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS)); assertFalse(b.isDone)
        val original = checkNotNull(a.pendingFinish)
        cleanup = {}
        assertTrue(sessions.retryCleanup(a.tasks.snapshot().id))
        assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        assertSame(original, a.finished)
        assertFalse(a.cleanupFailed)
        assertFalse(sessions.retryCleanup(a.tasks.snapshot().id)) // no second release after success
    }

    @Test fun retirementKeepsOldPhysicalBodyAndCleanupFencesAcrossLaunches() {
        val entered = CountDownLatch(1); val bodyExit = CountDownLatch(1)
        val cleanupEntered = CountDownLatch(1); val cleanupExit = CountDownLatch(1); val waiting = CountDownLatch(1)
        observe = {
            entered.countDown()
            var done = false
            while (!done) try { done = bodyExit.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
        }
        val oldCall = pool.submit<ToolOutput> { invoke("A", tool = PhoneToolCatalog.SCREEN) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val old = task("A"); val oldId = old.tasks.snapshot().id
            time.addAndGet(60_000)
            assertTrue(oldCall.get(5, TimeUnit.SECONDS).isError)
            assertTrue(old.running)
            cleanup = { id -> assertEquals(oldId, id); cleanupEntered.countDown(); assertTrue(cleanupExit.await(5, TimeUnit.SECONDS)) }
            sessions.retire()
            observe = {}
            changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForScreen"] == "main" }) waiting.countDown() }
            val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS)); assertFalse(b.isDone)
            assertTrue(sessions.snapshot().any { it["retiring"] == true && it["draining"] == true })
            bodyExit.countDown()
            assertTrue(cleanupEntered.await(5, TimeUnit.SECONDS)); assertFalse(b.isDone)
            cleanupExit.countDown()
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            assertNull(old.finished)
            assertTrue(task("B").tasks.isActive)
        } finally { bodyExit.countDown(); cleanupExit.countDown() }
    }

    @Test fun retiredAdmissionCannotBeginANewScopeOnReusedLegacyTasks() {
        invoke(null, tool = PhoneToolCatalog.SCREEN)
        val old = sessions.all().single { it.sessionId == null }
        val oldId = legacy.snapshot().id
        val oldAdmission = admit(null)
        val capturedEpoch = old.tasks.admissionEpoch()
        sessions.retire()
        assertFalse(invoke(null).isError)
        val newId = legacy.snapshot().id
        assertNotEquals(oldId, newId)
        // Even if retirement happened after the registry live check, begin itself rejects the epoch.
        assertTrue(legacy.begin(capturedEpoch) is PhoneTasks.Begin.Refused)
        assertTrue(sessions.run(oldAdmission, PhoneToolCatalog.APPS, emptyMap()).isError)
        assertEquals(newId, legacy.snapshot().id); assertTrue(legacy.isActive)
    }

    @Test fun explicitResumeAllowsOnlyFutureCallsForTheChosenSession() {
        invoke("A"); invoke("B")
        val a = task("A"); val b = task("B")
        sessions.stop(a, "user A"); sessions.stop(b, "user B")
        end("A")
        time.addAndGet(120_000)
        assertTrue(invoke("A", "next").isError)
        assertTrue(sessions.resume(a))
        assertFalse(invoke("A", "next").isError)
        assertTrue(invoke("A", "1").isError) // exact old run end never reopens
        assertTrue(invoke("B", "next").isError)
    }

    @Test fun lateLegacyBodyCleanupUsesItsOldIdWithoutEndingTheNextLaunchScope() {
        val entered = CountDownLatch(1); val exit = CountDownLatch(1); val cleaned = CountDownLatch(1)
        observe = {
            entered.countDown()
            var done = false
            while (!done) try { done = exit.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
        }
        val oldCall = pool.submit<ToolOutput> { invoke(null, tool = PhoneToolCatalog.SCREEN) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val oldId = legacy.snapshot().id
            time.addAndGet(60_000)
            assertTrue(oldCall.get(5, TimeUnit.SECONDS).isError)
            cleanup = { id -> assertEquals(oldId, id); cleaned.countDown() }
            sessions.retire()
            observe = {}
            assertFalse(invoke(null).isError) // metadata has no screen lease, and gets a fresh epoch
            val nextId = legacy.snapshot().id
            assertNotEquals(oldId, nextId)
            exit.countDown()
            assertTrue(cleaned.await(5, TimeUnit.SECONDS))
            assertEquals(nextId, legacy.snapshot().id); assertTrue(legacy.isActive)
        } finally { exit.countDown() }
    }

    @Test fun retiredCleanupRetryKeepsItsOldIdentityAndDoesNotResumeTheOldRun() {
        invoke(null, tool = PhoneToolCatalog.SCREEN)
        val oldId = legacy.snapshot().id
        cleanup = { throw IllegalStateException("unconfirmed") }
        sessions.retire()
        assertTrue(sessions.snapshot().any { it["retiring"] == true && it["cleanupFailed"] == true })
        assertFalse(invoke(null).isError)
        val currentId = legacy.snapshot().id
        cleanup = { id -> assertEquals(oldId, id) }
        assertTrue(sessions.retryCleanup(oldId))
        assertEquals(currentId, legacy.snapshot().id); assertTrue(legacy.isActive)
        assertFalse(sessions.snapshot().any { it["retiring"] == true })
    }

    @Test fun scheduledStopCleanupKeepsLeasesAndLegacyFinishWaitsForItsActualResult() {
        invoke(null, tool = PhoneToolCatalog.SCREEN)
        val legacyRecord = sessions.all().single { it.sessionId == null }
        val queued = java.util.concurrent.atomic.AtomicReference<(() -> Unit)?>(null)
        val ready = CountDownLatch(1)
        cleanupDispatch = { action -> queued.set(action); ready.countDown() }
        sessions.stop(legacyRecord, "user")
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        assertTrue(sessions.isBusy(legacyRecord)); assertFalse(legacyRecord.resourcesReleased)
        val finish = pool.submit<PhoneTasks.Owner?> { sessions.finish(legacyRecord) }
        cleanupDispatch = { it() } // background explicit finish uses the synchronous path
        pool.submit { checkNotNull(queued.get())() }.get(5, TimeUnit.SECONDS)
        assertNotNull(finish.get(5, TimeUnit.SECONDS))
        assertTrue(legacyRecord.resourcesReleased); assertFalse(sessions.isBusy(legacyRecord))
    }

    private fun openApp(session: String, pkg: String, background: Boolean = true): ToolOutput =
        sessions.run(admit(session), PhoneToolCatalog.OPEN, mapOf("app" to pkg, "background" to background))

    @Test fun nativePlanPreparationDoesNotOccupyTheSharedWorkerAndStopRejectsItsLateResult() {
        val entered = CountDownLatch(1); val exit = CountDownLatch(1)
        val launches = AtomicLong()
        prepareLaunch = { app -> entered.countDown(); assertTrue(exit.await(5, TimeUnit.SECONDS)); TestSystemLaunch(SystemTarget.Known(app)) }
        open = { launches.incrementAndGet(); ActionResult(true, "opened") }
        val preparing = pool.submit<ToolOutput> { openApp("A", "example.app") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertFalse(pool.submit<ToolOutput> { invoke("B") }.get(5, TimeUnit.SECONDS).isError)
            val a = task("A")
            assertEquals(1, a.pending); assertTrue(a.running)
            assertTrue(sessions.stop(a, "stop while preparing"))
            exit.countDown()
            assertTrue(preparing.get(5, TimeUnit.SECONDS).isError)
            assertEquals(0L, launches.get()); assertTrue(a.heldApps.isEmpty())
        } finally { exit.countDown() }
    }

    @Test fun retiringWhilePreparingCannotAcquireAliasesOrDispatchOnTheNextLaunch() {
        val entered = CountDownLatch(1); val exit = CountDownLatch(1)
        prepareLaunch = { app -> entered.countDown(); assertTrue(exit.await(5, TimeUnit.SECONDS)); TestSystemLaunch(SystemTarget.Known(app)) }
        val preparing = pool.submit<ToolOutput> { openApp("A", "example.app") }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val a = task("A")
            sessions.retire()
            assertFalse(invoke("B").isError)
            exit.countDown()
            assertTrue(preparing.get(5, TimeUnit.SECONDS).isError)
            assertTrue(a.heldApps.isEmpty()); assertTrue(a.resourcesReleased)
        } finally { exit.countDown() }
    }

    @Test fun resourceWaitPreservesTheExactPreparedPlanThroughTheActualCoreDispatch() {
        assertFalse(invoke("holder", tool = PhoneToolCatalog.SCREEN).isError)
        val prepared = TestSystemLaunch(SystemTarget.Known(appEntries.single()))
        val preparations = AtomicLong(); val launches = AtomicLong(); val waiting = CountDownLatch(1)
        prepareLaunch = { preparations.incrementAndGet(); time.addAndGet(5_000); prepared }
        launch = { actual, dispatch ->
            assertSame(prepared, actual); assertTrue(dispatch.commitStart()); launches.incrementAndGet()
            SysResult(false, "attempted once", actual.target)
        }
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown() }
        val call = pool.submit<ToolOutput> { openApp("B", "example.app", background = false) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS)); assertEquals(1L, preparations.get()); assertEquals(0L, launches.get())
        assertEquals(0L, sessions.snapshot().single { it["sessionId"] == "B" }["waitingForMs"]) // PM time is not resource-wait time.
        end("holder")
        assertTrue(call.get(5, TimeUnit.SECONDS).text.contains("attempted once"))
        assertEquals(1L, preparations.get()); assertEquals(1L, launches.get())
    }

    @Test fun appAliasesUseBothPackageAndFullUidAndPublishOnlyTheRequestersOwnPackage() {
        open = { ActionResult(true, "opened") }
        for ((index, pair) in listOf(
            PhoneAppIdentity("first.app", 10123) to PhoneAppIdentity("second.app", 10123),
            PhoneAppIdentity("same.app", 10123) to PhoneAppIdentity("same.app", 20234),
            PhoneAppIdentity("first.app", 10123) to PhoneAppIdentity("second.app", 20234),
        ).withIndex()) {
            val (first, second) = pair
            val a = "A$index"; val b = "B$index"
            appEntries = listOf(AppEntry("First", first))
            assertFalse(openApp(a, first.packageName).isError)
            appEntries = listOf(AppEntry("Second", second))
            val waiting = CountDownLatch(1)
            changed = { if (sessions.snapshot().any { it["sessionId"] == b && it["waitingForScreen"] != null }) waiting.countDown() }
            val call = pool.submit<ToolOutput> { openApp(b, second.packageName) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS))
            val view = sessions.snapshot().single { it["sessionId"] == b }
            if (index < 2) assertEquals(mapOf("kind" to "known", "packageName" to second.packageName), view["waitingForApp"])
            else assertNull(view["waitingForApp"]) // Still waits for the real single background display.
            assertEquals(0L, view["waitingForMs"])
            end(a)
            assertFalse(call.get(5, TimeUnit.SECONDS).isError)
            assertEquals(setOf(second), task(b).heldApps)
            end(b)
        }
    }

    @Test fun unknownMainWaitDoesNotOccupyTheWorkerAndStopClearsOnlyItsWaitingState() {
        val identity = PhoneAppIdentity("first.app", 10123)
        appEntries = listOf(AppEntry("First", identity)); open = { ActionResult(true, "opened") }
        assertFalse(openApp("A", identity.packageName).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { invoke("B", tool = PhoneToolCatalog.SCREEN) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        assertFalse(pool.submit<ToolOutput> { invoke("metadata") }.get(5, TimeUnit.SECONDS).isError)
        time.addAndGet(1_501)
        val view = sessions.snapshot().single { it["sessionId"] == "B" }
        assertEquals(mapOf("kind" to "unknown"), view["waitingForApp"])
        assertEquals(1_501L, view["waitingForMs"])
        assertTrue(sessions.stop(task("B"), "cancel waiting"))
        assertTrue(b.get(5, TimeUnit.SECONDS).isError)
        assertNull(sessions.snapshot().single { it["sessionId"] == "B" }["waitingForMs"])
        assertEquals(setOf(identity), task("A").heldApps)
    }

    @Test fun mainUnknownIsStickyAcrossReadResultsAndBlocksKnownBackgroundLaunch() {
        assertFalse(invoke("A", tool = PhoneToolCatalog.SCREEN).isError)
        assertTrue(task("A").holdsUnknownApp)
        assertFalse(invoke("A", tool = PhoneToolCatalog.SCREEN).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { openApp("B", "example.app") }
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        assertEquals(mapOf("kind" to "known", "packageName" to "example.app"), sessions.snapshot().single { it["sessionId"] == "B" }["waitingForApp"])
        assertTrue(sessions.stop(task("B"), "cancel")); assertTrue(b.get(5, TimeUnit.SECONDS).isError)
        assertTrue(task("A").holdsUnknownApp)
        end("A"); assertFalse(task("A").holdsUnknownApp)
    }

    @Test fun attemptedAppsStayReservedAcrossAnotherOpenAndTheSixteenthIdentityIsTheLastAdmission() {
        appEntries = (1..17).map { AppEntry("App$it", PhoneAppIdentity("pkg$it.app", 10000 + it)) }
        val opened = AtomicLong(); open = { opened.incrementAndGet(); ActionResult(true, "opened") }
        for (app in appEntries.take(16)) assertFalse(openApp("A", app.packageName).isError)
        assertEquals(appEntries.take(16).map { it.identity }.toSet(), task("A").heldApps)
        val refused = openApp("A", appEntries.last().packageName)
        assertTrue(refused.isError); assertTrue(refused.text.contains("16")); assertEquals(16L, opened.get())
        assertEquals(16, task("A").heldApps.size)
        assertFalse(openApp("A", appEntries.first().packageName).isError)
        end("A"); assertTrue(task("A").heldApps.isEmpty())
    }

    @Test fun strictCleanupFailureAndRetirementRetainAppAliasesUntilOriginalCleanupRetry() {
        val identity = PhoneAppIdentity("first.app", 10123)
        appEntries = listOf(AppEntry("First", identity)); open = { ActionResult(true, "opened") }
        assertFalse(openApp("A", identity.packageName).isError)
        val original = task("A"); val originalId = original.tasks.snapshot().id
        cleanup = { throw IllegalStateException("release unconfirmed") }
        sessions.retire()
        assertTrue(original.cleanupFailed); assertEquals(setOf(identity), original.heldApps)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { openApp("B", identity.packageName) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        cleanup = { assertEquals(originalId, it) }
        assertTrue(sessions.retryCleanup(originalId))
        assertFalse(b.get(5, TimeUnit.SECONDS).isError)
        assertTrue(original.heldApps.isEmpty()); assertEquals(setOf(identity), task("B").heldApps)
    }

    @Test fun appWaitingUsesTheSingleResourceDeadlineAndNeverDropsTheHoldersAliases() {
        val identity = PhoneAppIdentity("first.app", 10123)
        appEntries = listOf(AppEntry("First", identity)); open = { ActionResult(true, "opened") }
        assertFalse(openApp("A", identity.packageName).isError)
        val waiting = CountDownLatch(1)
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { openApp("B", identity.packageName) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        time.addAndGet(30_001)
        val out = b.get(5, TimeUnit.SECONDS)
        assertTrue(out.isError); assertTrue(out.text.contains("屏幕或应用"))
        assertEquals(setOf(identity), task("A").heldApps)
        assertTrue(task("B").heldApps.isEmpty())
    }

    @Test fun timedOutLaunchRetainsAppAliasesUntilItsBodyAndStrictCleanupBothFinish() {
        val identity = PhoneAppIdentity("first.app", 10123)
        appEntries = listOf(AppEntry("First", identity))
        val entered = CountDownLatch(1); val bodyExit = CountDownLatch(1)
        val cleanupEntered = CountDownLatch(1); val cleanupExit = CountDownLatch(1); val waiting = CountDownLatch(1)
        open = {
            entered.countDown()
            var done = false
            while (!done) try { done = bodyExit.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
            ActionResult(true, "opened")
        }
        val a = pool.submit<ToolOutput> { openApp("A", identity.packageName) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val original = task("A")
            time.addAndGet(120_000)
            assertTrue(a.get(5, TimeUnit.SECONDS).isError)
            assertTrue(original.running); assertEquals(setOf(identity), original.heldApps)
            cleanup = { cleanupEntered.countDown(); assertTrue(cleanupExit.await(5, TimeUnit.SECONDS)) }
            end("A")
            changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown() }
            open = { ActionResult(true, "opened next") }
            val b = pool.submit<ToolOutput> { openApp("B", identity.packageName) }
            assertTrue(waiting.await(5, TimeUnit.SECONDS)); assertFalse(b.isDone)
            bodyExit.countDown()
            assertTrue(cleanupEntered.await(5, TimeUnit.SECONDS))
            assertEquals(setOf(identity), original.heldApps); assertFalse(b.isDone)
            cleanupExit.countDown()
            assertFalse(b.get(5, TimeUnit.SECONDS).isError)
            assertTrue(original.heldApps.isEmpty())
        } finally { bodyExit.countDown(); cleanupExit.countDown() }
    }

    @Test fun chooserHasNoInventedKnownIdentityAndDispatchesItsOriginalPlanOnce() {
        assertFalse(invoke("holder", tool = PhoneToolCatalog.SCREEN).isError)
        val chooser = TestSystemLaunch(SystemTarget.UserChoice, "url")
        val prepared = AtomicLong(); val started = AtomicLong(); val waiting = CountDownLatch(1)
        prepareUrl = { prepared.incrementAndGet(); chooser }
        launch = { plan, dispatch ->
            assertSame(chooser, plan); assertTrue(dispatch.commitStart()); started.incrementAndGet()
            SysResult(false, "chooser attempted", plan.target)
        }
        changed = { if (sessions.snapshot().any { it["sessionId"] == "B" && it["waitingForApp"] != null }) waiting.countDown() }
        val b = pool.submit<ToolOutput> { sessions.run(admit("B"), PhoneToolCatalog.OPEN, mapOf("url" to "https://example.com/")) }
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        assertEquals(mapOf("kind" to "unknown"), sessions.snapshot().single { it["sessionId"] == "B" }["waitingForApp"])
        end("holder")
        assertTrue(b.get(5, TimeUnit.SECONDS).text.contains("chooser attempted"))
        assertEquals(1L, prepared.get()); assertEquals(1L, started.get())
        assertTrue(task("B").holdsUnknownApp); assertTrue(task("B").heldApps.isEmpty())
    }


    @Test fun oldPhysicalRecoveryBlocksMainBackgroundAndAppsBeforeBeginOrPreparation() {
        val lookups = AtomicLong(); val reads = AtomicLong()
        lookup = { lookups.incrementAndGet() }; observe = { reads.incrementAndGet() }
        recoveryAdmission = { BackgroundResourceJournal.REFUSAL }
        val calls = listOf(
            Triple("main", PhoneToolCatalog.SCREEN, emptyMap<String, Any?>()),
            Triple("background", PhoneToolCatalog.SCREEN, mapOf<String, Any?>("background" to true)),
            Triple("apps", PhoneToolCatalog.APPS, emptyMap<String, Any?>()),
            Triple("open", PhoneToolCatalog.OPEN, mapOf<String, Any?>("app" to "example.app")),
        )
        for ((session, tool, args) in calls) {
            val output = sessions.run(admit(session), tool, args)
            assertTrue(output.isError); assertEquals(BackgroundResourceJournal.REFUSAL, output.text)
            assertEquals(0L, task(session).tasks.snapshot().id)
        }
        assertEquals(0L, lookups.get()); assertEquals(0L, reads.get())
        assertEquals(0L, actions.get()); assertEquals(0, journalCount())
    }

    @Test fun logicalAcknowledgementDoesNotBypassTheIndependentPhysicalAdmission() {
        val old = PhoneTaskJournal({ journalBytes }, { journalBytes = it; true },
            "00000000-0000-4000-8000-000000000001")
        old.load()
        val previousTasks = PhoneTasks(clock = ::taskClock, idSource = ids::incrementAndGet)
        val begin = previousTasks.begin() as PhoneTasks.Begin.Go
        assertTrue(old.mark(old.record(begin.owner)))
        journal.load()
        assertTrue(journal.acknowledge(journal.status()["batchToken"] as String))
        recoveryAdmission = { BackgroundResourceJournal.REFUSAL }
        val output = invoke("after-ack")
        assertTrue(output.isError); assertEquals(BackgroundResourceJournal.REFUSAL, output.text)
        assertEquals(0L, task("after-ack").tasks.snapshot().id)
        recoveryAdmission = { null }
        assertFalse(invoke("new-after-physical-proof").isError)
    }

    @Test fun currentProcessPhysicalRecordDoesNotGloballyBlockAnotherCall() {
        val physical = BackgroundResourceJournal({ null }, { true },
            "00000000-0000-4000-8000-000000000002")
        assertTrue(physical.load())
        val birth = BackgroundResourceJournal.Birth(
            "00000000-0000-4000-8000-000000000003",
            "00000000-0000-4000-8000-000000000004", 123, 2000, 1L, 2L)
        assertTrue(physical.mark(physical.record(
            "00000000-0000-4000-8000-000000000005", "task", birth, "portrait")))
        assertEquals("clear", physical.status().state)
        recoveryAdmission = {
            if (physical.status().state == "clear") null else BackgroundResourceJournal.REFUSAL
        }
        assertFalse(invoke("current-process").isError)
        assertTrue(task("current-process").tasks.snapshot().active)
    }

}
