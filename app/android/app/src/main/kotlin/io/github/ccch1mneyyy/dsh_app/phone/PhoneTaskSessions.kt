package io.github.ccch1mneyyy.dsh_app.phone

/**
 * Per-launch session admission. The registry lock protects attribution, pending calls and screen/App
 * leases only. It is never held across driver work, UI waits, listeners or a worker join.
 * Lease waits happen before the selected screen worker, so a holder can continue and release.
 */
class PhoneTaskSessions(
    private val clock: () -> Long,
    private val idSource: () -> Long,
    private val create: (PhoneTasks, String?) -> PhoneCore,
    legacyTasks: PhoneTasks,
    legacyCore: PhoneCore,
    private val changed: () -> Unit = {},
    private val onSettled: (Task) -> Unit = {},
    private val maxRuns: Int = MAX_RUNS_PER_LAUNCH,
    private val settleResources: (Long) -> Unit = {},
    private val dispatchCleanup: (() -> Unit) -> Unit = { it() },
    // These leaf callbacks perform bounded trace/draft memory work only; never emit UI or perform IO.
    private val startSkillScope: (PhoneTasks.Owner) -> Long? = { null },
    private val completeSkillScope: (PhoneTasks.Owner, Long, String) -> Boolean = { _, _, _ -> false },
    // Runs outside registry/Tasks locks while this record cannot start or resume another scope.
    private val cancelScope: (Task, PhoneTasks.Snapshot) -> Unit = { task, state ->
        if (state.stopped) task.activeWorker?.interruptCurrent(task.tasks)
    },
    private val journal: PhoneTaskJournal? = null,
    private val recoveryAdmission: () -> String? = { null },
    private val createBackgroundWorker: () -> SerialWorker = { SerialWorker("dsh-phone-background") },
) {
    internal class SkillScope(val owner: PhoneTasks.Owner, val draftEpoch: Long, val launchEpoch: Long) {
        var endOwner: PhoneTasks.Owner? = null
        var cancelled = false
        var settled = false
    }
    class Task internal constructor(val sessionId: String?, val runId: String?, val tasks: PhoneTasks, val core: PhoneCore) {
        internal var pending = 0
        internal var running = false
        @Volatile internal var activeWorker: SerialWorker? = null
        internal var backgroundWorker: SerialWorker? = null
        internal var closing = false
        internal var stopped = false
        internal var cancelling = false
        internal var cancelledLifecycle: Long? = null
        @Volatile internal var retired: PhoneTasks.Snapshot? = null
        @Volatile internal var resourcesReleased = true
        @Volatile internal var resourceTaskId = 0L
        internal var cleanupFailed = false
        // Full requested set while waiting; holders can change before this waiter wakes.
        internal var waitingScreens: List<PhoneScreen> = emptyList()
        internal var waitingApp: PhoneAppIdentity? = null
        internal var waitingUnknownApp = false
        internal var waitingSince: Long? = null
        internal val heldApps = linkedSetOf<PhoneAppIdentity>()
        internal var holdsUnknownApp = false
        internal var endRequested = false
        internal var ending = false
        internal var endSettled = false
        internal var finished: PhoneTasks.Owner? = null
        internal var pendingFinish: PhoneTasks.Owner? = null
        internal var returnClaimed = false
        internal var skillScope: SkillScope? = null
        internal var journalRecord: PhoneTaskJournal.Record? = null
        internal var journalMarked = false
        internal var journalEnded = false
        internal var journalFailed = false
        var completion: String = "unknown"
            internal set
    }
    class Admission internal constructor(internal val task: Task?, internal val epoch: Long, internal val refusal: String? = null, internal val scopeEpoch: Long? = task?.tasks?.admissionEpoch())
    private val mainWorker = legacyCore.worker
    private val lock = Object()
    private var epoch = 0L
    private var resetting = false
    private val retiring = linkedSetOf<Task>()
    private data class Key(val sessionId: String?, val runId: String?)
    private var legacy = Task(null, null, legacyTasks, legacyCore)
    private val entries = linkedMapOf(Key(null, null) to legacy)
    private val stoppedSessions = HashSet<String?>()
    private val endedRuns = HashMap<Key, String>()
    private val retainedRuns = HashSet<Key>()
    private val lastAdmitted = mutableMapOf<String?, Task>()
    private val screens = mutableMapOf<PhoneScreen, Task>()
    // Includes retired records until their original physical cleanup succeeds.
    private val appHolders = linkedSetOf<Task>()
    class SelfCheckLease internal constructor(internal val epoch: Long) {
        internal var sealed = false
    }
    private var selfCheck: SelfCheckLease? = null

    /** Local diagnostic reservation, never a synthetic task or skill scope. */
    fun tryReserveSelfCheck(): SelfCheckLease? = synchronized(lock) {
        if (resetting || selfCheck != null || screens.isNotEmpty() || appHolders.isNotEmpty() || retiring.isNotEmpty()) return null
        if (entries.values.any { it.pending > 0 || it.running || it.closing || it.cancelling ||
                it.cleanupFailed || it.ending || it.endRequested && !it.endSettled || it.tasks.isActive }) return null
        SelfCheckLease(epoch).also { selfCheck = it }
    }

    fun selfCheckCurrent(lease: SelfCheckLease): Boolean = synchronized(lock) {
        selfCheck === lease && !lease.sealed && lease.epoch == epoch && !resetting
    }

    fun sealSelfCheck(lease: SelfCheckLease) = synchronized(lock) {
        if (selfCheck === lease) lease.sealed = true
    }

    /** The original diagnostic owner returns this only after its physical work has drained/released. */
    fun releaseSelfCheck(lease: SelfCheckLease): Boolean = synchronized(lock) {
        if (selfCheck !== lease) false
        else { selfCheck = null; lock.notifyAll(); true }
    }

    /** Local on-device read, without a model task. Null means an existing owner is busy. */
    fun <T> readForSelfCheck(worker: SerialWorker, budgetMs: Long, maxTotalMs: Long, read: () -> T): SerialWorker.Outcome<T>? {
        val lease = tryReserveSelfCheck() ?: return null
        try {
            val result = worker.run(budgetMs, maxTotalMs, owner = lease) {
                if (!selfCheckCurrent(lease) || Thread.currentThread().isInterrupted) throw InterruptedException()
                read()
            }
            return if (selfCheckCurrent(lease)) result else SerialWorker.Outcome.Interrupted
        } finally {
            // Timeout/cancel may return before the original system read. Never release its
            // reservation until that exact body's finally has run, including across retire.
            worker.afterDrained(lease) { releaseSelfCheck(lease) }
        }
    }

    /** Called while PhoneBridge still holds its launch lock, before dispatch enters its pool. */
    fun admit(attribution: PhoneCaller?): Admission = synchronized(lock) {
        // l10n:keep agent resource admission
        if (selfCheck != null) return Admission(null, epoch, "本地自检正在占用手机，请稍后重试。")
        if (resetting || retiring.any { it.cancelling }) return Admission(null, epoch, PhoneTasks.STOPPED_MESSAGE)
        // B1 attribution alone does not prove the client can deliver an exact run end.
        val caller = attribution?.takeIf { it.runLifecycle == 1 }
        val key = Key(caller?.sessionId, caller?.runId)
        if (caller != null) {
            if (key in endedRuns || caller.sessionId in stoppedSessions) return Admission(null, epoch, PhoneTasks.STOPPED_MESSAGE)
            if (!reserve(key)) return Admission(null, epoch, CAPACITY_MESSAGE)
        }
        val task = entries.getOrPut(key) {
            val tasks = PhoneTasks(clock = clock, idleMs = Long.MAX_VALUE, idSource = idSource)
            Task(caller!!.sessionId, caller.runId, tasks, create(tasks, caller.sessionId))
        }
        if (!blocked(task) && !task.closing) lastAdmitted[task.sessionId] = task
        task.pending++
        Admission(task, epoch)
    }

    fun run(admission: Admission, name: String, args: Map<String, Any?>): ToolOutput {
        val task = admission.task ?: return ToolOutput(checkNotNull(admission.refusal), isError = true)
        var owner: PhoneTasks.Owner? = null
        var prepared: PhoneCore.PreparedCall? = null
        var running = false
        var executionWorker: SerialWorker? = null
        task.tasks.callStarted()
        try {
            recoveryAdmission()?.let { return ToolOutput(it, isError = true) }
            journal?.refusal()?.let { return ToolOutput(it, isError = true) }
            task.core.rejection(name)?.let { return it }
            synchronized(lock) {
                while (task.running && live(admission) && !blocked(task) && !task.closing) lock.wait(1_000)
                if (!live(admission) || blocked(task) || task.closing) return stopped()
                task.running = true
                running = true
            }
            // Legacy can start another logical task in this same record. Clean the prior
            // scope before beginning it, while this call exclusively owns the execution slot.
            if (task.sessionId == null && !task.tasks.isActive && !task.resourcesReleased) {
                try { releasePhysical(task, task.resourceTaskId) } catch (_: Exception) {
                    synchronized(lock) { task.cleanupFailed = true }
                    return stopped()
                }
            }
            owner = when (val b = task.tasks.begin(admission.scopeEpoch)) {
                is PhoneTasks.Begin.Go -> {
                    if (b.newTask) {
                        // A legacy idle rollover can create a scope before its old inactive
                        // listener settles. Do not overwrite that old trace/resource identity.
                        val previous = synchronized(lock) { task.skillScope?.takeUnless { it.settled } }
                        if (previous != null) {
                            try {
                                if (!task.resourcesReleased) releasePhysical(task, task.resourceTaskId)
                                synchronized(lock) { settleSkill(task, null) }
                            } catch (_: Exception) {
                                synchronized(lock) { task.cleanupFailed = true }
                                task.tasks.stop("旧任务清理尚未确认") // l10n:keep agent lifecycle result
                                return stopped()
                            }
                        }
                        synchronized(lock) {
                            if (live(admission) && !blocked(task)) task.tasks.runIfCurrent(b.owner) {
                                startSkillScope(b.owner)?.let { draftEpoch ->
                                    task.skillScope = SkillScope(b.owner, draftEpoch, admission.epoch)
                                }
                            }
                        }
                    }
                    b.owner
                }
                is PhoneTasks.Begin.Refused -> return ToolOutput(b.message, isError = true)
            }
            if (journal != null) {
                val previous = synchronized(lock) { task.journalRecord }
                if (previous != null && (previous.taskId != owner.taskId || previous.lifecycle != owner.lifecycle)) {
                    // A real owner replacement (including clearStop) cannot overwrite an old token.
                    try { if (!task.resourcesReleased) releasePhysical(task, task.resourceTaskId) }
                    catch (_: Exception) { synchronized(lock) { task.cleanupFailed = true }; return stopped() }
                    synchronized(lock) {
                        task.skillScope?.takeIf { it.owner.taskId == previous.taskId && it.owner.lifecycle == previous.lifecycle }
                            ?.let { settleSkill(task, null) }
                        task.journalEnded = true
                    }
                    if (!clearJournal(task)) return ToolOutput(PhoneTaskJournal.STORAGE_MESSAGE, isError = true)
                }
                val record = synchronized(lock) { task.journalRecord } ?: journal.record(owner)
                synchronized(lock) {
                    if (!live(admission) || blocked(task) || !task.tasks.isCurrent(owner)) return stopped()
                    task.journalRecord = record
                }
                if (!task.journalMarked) {
                    if (!journal.mark(record)) return ToolOutput(PhoneTaskJournal.STORAGE_MESSAGE, isError = true)
                    synchronized(lock) { task.journalMarked = true }
                }
                synchronized(lock) {
                    if (!live(admission) || blocked(task) || !task.tasks.isCurrent(owner)) return stopped()
                }
            }
            if (task.tasks.isPaused && !task.tasks.awaitResume(PhoneCore.PAUSE_WAIT_MS)) return stopped()
            val call = when (val result = task.core.prepareCall(name, args, owner)) {
                is Either.Left -> return result.value
                is Either.Right -> result.value
            }
            prepared = call
            val failure = awaitResources(admission, call)
            if (failure != null) return ToolOutput(failure, isError = true)
            val selected = synchronized(lock) {
                if (!live(admission) || blocked(task) || !task.tasks.isCurrent(owner)) return stopped()
                val lane = if (PhoneScreen.BACKGROUND in call.screens) {
                    check(screens[PhoneScreen.BACKGROUND] === task)
                    task.backgroundWorker ?: createBackgroundWorker().also { task.backgroundWorker = it }
                } else mainWorker
                task.activeWorker = lane
                executionWorker = lane
                lane
            }
            return task.core.call(call, selected)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return stopped()
        } finally {
            task.tasks.callEnded(owner)
            synchronized(lock) { task.pending--; lock.notifyAll() }
            if (running) {
                // A timed-out Future can return before its device body. Keep the task's
                // execution slot and screen leases until that exact owner physically drains.
                val completedCall = prepared
                val drained = {
                    synchronized(lock) {
                        if (completedCall != null && completedCall.borrowedMainForBackgroundOpen &&
                            completedCall.backgroundOpenConfirmed && live(admission) && !blocked(task) &&
                            !task.closing && screens[PhoneScreen.MAIN] === task) {
                            task.tasks.runIfCurrent(completedCall.owner) { screens.remove(PhoneScreen.MAIN) }
                        }
                        // Keep this execution slot until the exact original MAIN decision is committed.
                        task.activeWorker = null
                        task.running = false
                        clearWaiting(task)
                        lock.notifyAll()
                    }
                    settled(task)
                }
                val original = executionWorker
                if (original == null) drained() else original.afterDrained(task.tasks, drained)
            } else settled(task)
            changed()
        }
    }

    private fun settled(task: Task) {
        settleInactive(task)
        onSettled(task)
        changed()
    }

    private fun live(a: Admission) = a.epoch == epoch && a.task?.let { entries[Key(it.sessionId, it.runId)] === it } == true
    private fun blocked(task: Task) = task.journalFailed || task.cancelling || task.retired != null || task.cleanupFailed || task.endRequested || task.sessionId != null && (task.stopped || task.sessionId in stoppedSessions)
    private fun stopped() = ToolOutput(PhoneTasks.STOPPED_MESSAGE + "。", isError = true)

    private fun appBlockers(task: Task, known: PhoneAppIdentity?, unknown: Boolean): List<Task> =
        appHolders.filter { holder -> holder !== task && (unknown ||
            known != null && (holder.holdsUnknownApp || holder.heldApps.any {
                it.packageName == known.packageName || it.uid == known.uid
            })) }

    private fun blockers(task: Task, needed: List<PhoneScreen>, known: PhoneAppIdentity?, unknown: Boolean): Set<Task> =
        (needed.mapNotNull { screens[it]?.takeUnless { holder -> holder === task } } +
            appBlockers(task, known, unknown)).toSet()

    private fun clearWaiting(task: Task) {
        task.waitingScreens = emptyList()
        task.waitingApp = null
        task.waitingUnknownApp = false
        task.waitingSince = null
    }

    private fun awaitResources(a: Admission, call: PhoneCore.PreparedCall): String? {
        val needed = call.screens
        val known = call.knownApp
        val unknown = call.unknownApp
        if (needed.isEmpty() && known == null && !unknown) return null
        val started = clock()
        val until = started + 30_000
        val task = checkNotNull(a.task)
        fun current() = live(a) && !blocked(task) && task.tasks.isCurrent(call.owner)
        fun acquire() {
            call.borrowedMainForBackgroundOpen = call.name == PhoneToolCatalog.OPEN &&
                call.args.bool("background") == true && PhoneScreen.MAIN in needed && screens[PhoneScreen.MAIN] == null
            needed.forEach { screens[it] = task }
            if (known != null) task.heldApps += known
            if (unknown) task.holdsUnknownApp = true
            if (known != null || unknown) appHolders += task
            task.resourcesReleased = false
            task.resourceTaskId = call.owner.taskId
        }
        synchronized(lock) {
            if (!current()) return PhoneTasks.STOPPED_MESSAGE
            if (known != null && known !in task.heldApps && task.heldApps.size >= MAX_APPS_PER_SCOPE)
                return "本任务已保留 16 个应用身份，请结束并清理本任务后再打开其他应用。" // l10n:keep agent resource result
            if (blockers(task, needed, known, unknown).isEmpty()) { acquire(); return null }
            // Whole request, not the first blocker: another holder can appear before wakeup.
            task.waitingScreens = needed
            task.waitingApp = known
            task.waitingUnknownApp = unknown
            task.waitingSince = started
        }
        changed()
        try {
            synchronized(lock) {
                while (true) {
                    if (!current()) return PhoneTasks.STOPPED_MESSAGE
                    val missing = blockers(task, needed, known, unknown)
                    if (missing.isEmpty()) { acquire(); return null }
                    val pending = java.util.ArrayDeque<Task>(missing)
                    val seen = HashSet<Task>()
                    while (pending.isNotEmpty()) {
                        val cursor = pending.removeFirst()
                        if (cursor === task) return "屏幕或应用资源形成等待环，本次没有操作。请结束或交还另一任务占用的资源后重试。" // l10n:keep agent resource result
                        if (seen.add(cursor)) blockers(cursor, cursor.waitingScreens,
                            cursor.waitingApp, cursor.waitingUnknownApp).forEach(pending::addLast)
                    }
                    val left = until - clock()
                    if (left <= 0) return "屏幕或应用资源正被另一个对话使用，已等待 30 秒，本次没有操作。请稍后再试或结束占用任务。" // l10n:keep agent resource result
                    lock.wait(minOf(left, 1_000))
                }
            }
        } finally {
            synchronized(lock) { clearWaiting(task) }
            changed()
        }
    }

    fun task(taskId: Long): Task? = all().firstOrNull { it.tasks.snapshot().id == taskId }
    fun all(): List<Task> = synchronized(lock) { entries.values.toList() }
    fun isBusy(task: Task): Boolean = synchronized(lock) { task.pending > 0 || task.running || task.closing || task.cancelling || task.cleanupFailed }

    /** Any record, selected or not, that may still act: active, an admitted call, or a draining body. */
    fun anyActive(): Boolean = synchronized(lock) {
        (entries.values + retiring).any { it.pending > 0 || it.running || it.retired == null && it.tasks.snapshot().active }
    }

    /** End/stop/idle/retirement all keep physical leases until body AND resource cleanup drain. */
    fun settleInactive(task: Task) { settle(task, explicitFinish = false) }

    private fun settle(task: Task, explicitFinish: Boolean, retry: Boolean = false, expected: PhoneTasks.Snapshot? = null): PhoneTasks.Owner? {
        val state: PhoneTasks.Snapshot
        val shouldFinish: Boolean
        val drainWorker: SerialWorker
        synchronized(lock) {
            if (task.pending > 0 || task.running || task.closing || task.cancelling || task.ending || task.cleanupFailed && !retry || task.journalFailed) return null
            // Capture only after excluding a new registry run, in registry -> Tasks lock order.
            state = task.retired ?: task.tasks.snapshot()
            if (expected != null && (!registered(task) || state.id != expected.id || state.lifecycle != expected.lifecycle)) return null
            if (retry && !task.cleanupFailed) return null
            shouldFinish = task.retired == null && (explicitFinish || task.endRequested && !task.endSettled)
            if (!shouldFinish && task.retired == null && state.active) return null
            if (!shouldFinish && task.resourcesReleased && task.skillScope?.settled != false && task.journalRecord == null) { retiring.remove(task); return null }
            task.closing = true
            task.cleanupFailed = false
            drainWorker = task.activeWorker ?: task.backgroundWorker ?: mainWorker
        }
        changed()
        var result: PhoneTasks.Owner? = null
        drainWorker.afterDrained(task.tasks) {
            dispatchCleanup {
                try {
                    // finishScope fires listeners. closing prevents their reentrant cleanup/admission.
                    val ended = if (shouldFinish && task.retired == null) task.pendingFinish ?: task.tasks.finishScope(state.id) else null
                    synchronized(lock) { task.pendingFinish = ended }
                    if (!task.resourcesReleased) releasePhysical(task, task.resourceTaskId)
                    synchronized(lock) { task.journalEnded = true }
                    if (!clearJournal(task)) return@dispatchCleanup
                    synchronized(lock) {
                        task.resourcesReleased = true
                        if (task.endRequested) task.endSettled = true
                        // A concurrent old-scope cancellation may still be outside the lock.
                        // Its launch fence survives successful physical cleanup until it returns.
                        if (!task.cancelling) retiring.remove(task)
                        settleSkill(task, ended)
                        // A successful cleanup consumes this retry token; legacy reuses the Task record.
                        task.pendingFinish = null
                        if (task.retired == null && ended != null && task.tasks.isCurrent(ended)) {
                            task.finished = ended
                            if (task.sessionId == null) task.stopped = false
                            result = ended
                        }
                        lock.notifyAll()
                    }
                } catch (_: Exception) {
                    // A failed release does not prove the display/body is gone. Keep its physical fence.
                    synchronized(lock) { task.cleanupFailed = true }
                } finally {
                    synchronized(lock) { task.closing = false; lock.notifyAll() }
                    onSettled(task)
                    changed()
                }
            }
        }
        return result
    }
    private fun clearJournal(task: Task): Boolean {
        val record = synchronized(lock) { task.journalRecord } ?: return true
        val ok = checkNotNull(journal).clear(record) // Never called under registry/Tasks locks.
        synchronized(lock) {
            if (ok) { task.journalRecord = null; task.journalMarked = false; task.journalEnded = false }
            task.journalFailed = !ok
        }
        return ok
    }

    /** Plugin I/O consumer: only exact tokens whose body/physical cleanup already finished. */
    fun retryJournalStorage(): Boolean {
        val store = journal ?: return true
        if (!store.retryStorage()) { changed(); return false }
        val failed = synchronized(lock) { (entries.values + retiring).distinct().filter { it.journalFailed } }
        var ok = true
        for (task in failed) {
            val claimed = synchronized(lock) {
                if (!task.journalEnded || task.running || task.pending > 0 || task.closing || task.cancelling) false
                else { task.closing = true; true }
            }
            if (!claimed) { ok = false; continue }
            try { if (!clearJournal(task)) ok = false }
            finally { synchronized(lock) { task.closing = false; lock.notifyAll() } }
            settleInactive(task)
        }
        changed()
        return ok
    }

    /** Registry lock held; invoked only after the old body AND its resource cleanup completed. */
    private fun settleSkill(task: Task, finished: PhoneTasks.Owner?) {
        val skill = task.skillScope?.takeUnless { it.settled } ?: return
        val originalEnd = skill.endOwner
        val eligible = task.sessionId != null && task.endRequested && task.completion == "completed" &&
            !skill.cancelled && task.retired == null && skill.launchEpoch == epoch &&
            originalEnd != null && originalEnd.taskId == skill.owner.taskId && originalEnd.lifecycle == skill.owner.lifecycle
        if (eligible && finished != null && task.tasks.runIfCurrent(finished) {
                completeSkillScope(skill.owner, skill.draftEpoch, "completed")
                skill.settled = true
            }) return
        completeSkillScope(skill.owner, skill.draftEpoch, if (task.completion == "completed") "other" else task.completion)
        skill.settled = true
    }

    /** A user retry only repeats cleanup for the original physical task; it never resumes work. */
    fun retryCleanup(taskId: Long): Boolean {
        val task = synchronized(lock) {
            (entries.values + retiring).firstOrNull {
                it.cleanupFailed && (it.retired ?: it.tasks.snapshot()).id == taskId
            }
        } ?: return false
        settle(task, explicitFinish = false, retry = true)
        return synchronized(lock) { task.resourcesReleased && !task.cleanupFailed && !task.closing }
    }

    private fun releasePhysical(task: Task, taskId: Long) {
        settleResources(taskId) // Can block in platform IPC; neither registry nor worker lock is held.
        val retiredWorker = synchronized(lock) {
            task.resourcesReleased = true
            screens.entries.removeAll { it.value === task }
            appHolders.remove(task)
            task.heldApps.clear()
            task.holdsUnknownApp = false
            val lane = task.backgroundWorker
            task.backgroundWorker = null
            lock.notifyAll()
            lane
        }
        // Both normal settlement and legacy scope rollover reach this successful cleanup.
        retiredWorker?.shutdown()
    }

    fun snapshot(): List<Map<String, Any?>> = synchronized(lock) { (entries.values + retiring).distinct() }.map { task ->
        val state = task.retired ?: task.tasks.snapshot()
        val at = clock()
        val extra = synchronized(lock) {
            val waitingApp = if (task.waitingSince == null || appBlockers(task, task.waitingApp, task.waitingUnknownApp).isEmpty()) null
                else if (task.waitingUnknownApp) mapOf("kind" to "unknown")
                else mapOf("kind" to "known", "packageName" to checkNotNull(task.waitingApp).packageName)
            mapOf("sessionId" to task.sessionId, "runId" to task.runId,
            "identity" to if (task.sessionId == null) "legacy" else "session",
            "waitingForScreen" to task.waitingScreens.firstOrNull { screens[it] != null && screens[it] !== task }?.name?.lowercase(), "waitingForApp" to waitingApp,
            "waitingForMs" to task.waitingSince?.let { (at - it).coerceAtLeast(0L) }, "pendingCalls" to task.pending,
            "retiring" to (task.retired != null), "settling" to task.closing, "cleanupFailed" to task.cleanupFailed,
            "finishing" to (task.closing || task.cleanupFailed || task.retired != null || task.endRequested && !task.endSettled), "draining" to (task.running && task.pending == 0),
            "stopped" to (task.retired != null || task.stopped || state.stopped || task.sessionId in stoppedSessions), "generation" to state.lifecycle,
            "completion" to task.completion, "endedRunId" to task.finished?.let { task.runId }, "endedGeneration" to task.finished?.lifecycle) }
        state.toMap() + extra + if (task.retired != null) mapOf("active" to false) else emptyMap()
    }

    /** Short registry -> Tasks commit; callbacks cannot cancel a successor in this record. */
    fun stop(task: Task, owner: PhoneTasks.Owner, reason: String): Boolean =
        stopCommitted(task) { task.tasks.stopForOwner(owner, reason) }

    fun stop(task: Task, expected: PhoneTasks.Snapshot, reason: String): Boolean =
        stopCommitted(task) { task.tasks.stopForSnapshot(expected, reason) }

    fun stop(task: Task, reason: String): Boolean = stop(task, task.tasks.snapshot(), reason)

    private fun stopCommitted(task: Task, commit: () -> PhoneTasks.Change?): Boolean {
        val change = synchronized(lock) {
            if (!registered(task) || task.cancelling) return false
            val committed = commit() ?: return false
            claimCancellation(task, committed.snapshot)
            committed
        }
        try {
            cancelScope(task, change.snapshot)
        } finally {
            try { task.tasks.publish(change) } finally { cancellationFinished(task) }
        }
        return true
    }

    /** An old listener snapshot may never interrupt or dismiss work in a later scope. */
    fun onInactive(task: Task, state: PhoneTasks.Snapshot): Boolean {
        if (state.active) return false
        val claimed = synchronized(lock) {
            if (!registered(task) || task.cancelling || task.cancelledLifecycle == state.lifecycle) return false
            // A registry run may already own the slot but not yet have called begin().
            // Non-stop idle/end notices cannot cancel that successor reservation. A real
            // stop advances admissionEpoch, so the reserved old call cannot begin afterward.
            if (!state.stopped && task.running) return false
            task.tasks.runIfInactive(state) { claimCancellation(task, state) }
        }
        if (!claimed) return false
        try { cancelScope(task, state) } finally { cancellationFinished(task) }
        return true
    }

    private fun registered(task: Task) = entries[Key(task.sessionId, task.runId)] === task && task.retired == null

    // Registry is held after an exact Tasks stop commit (epoch advanced) or inside its inactive guard. Memory only.
    private fun claimCancellation(task: Task, state: PhoneTasks.Snapshot) {
        task.cancelling = true
        task.cancelledLifecycle = state.lifecycle
        if (state.stopped) {
            task.skillScope?.cancelled = true
            if (task.sessionId != null) { task.stopped = true; stoppedSessions += task.sessionId }
        }
        lock.notifyAll()
    }

    private fun cancellationFinished(task: Task) {
        synchronized(lock) { task.cancelling = false; lock.notifyAll() }
        settleInactive(task)
        changed()
    }

    fun resume(task: Task, expected: PhoneTasks.Snapshot = task.tasks.snapshot()): Boolean {
        val changes = synchronized(lock) {
            if (!registered(task) || retiring.any { it.cancelling }) return false
            val current = task.tasks.snapshot()
            if (current.id != expected.id || current.lifecycle != expected.lifecycle) return false
            val records = entries.values.filter { it.sessionId == task.sessionId }
            if (records.any { it.pending > 0 || it.running || it.closing || it.cancelling || it.cleanupFailed || !it.resourcesReleased || it.skillScope?.settled == false || it.journalRecord != null && !it.tasks.isActive }) return false
            // Commit clearStop/unpause while admission is still fenced. Publication is lock-free.
            val committed = records.map { record ->
                val expected = record.tasks.snapshot()
                val change = record.tasks.resumeForSnapshot(expected) ?: return false
                record to change
            }
            stoppedSessions -= task.sessionId
            records.forEach { it.stopped = false }
            committed
        }
        changes.forEach { (record, change) -> record.tasks.publish(change) }
        changed()
        return true
    }
    fun finish(task: Task, expected: PhoneTasks.Snapshot = task.tasks.snapshot()): PhoneTasks.Owner? {
        if (task.sessionId != null) return null // Modern completion only accepts exact host run-end.
        val until = System.nanoTime() + 3_000_000_000L
        synchronized(lock) {
            while (task.closing) {
                val left = (until - System.nanoTime()) / 1_000_000
                if (left <= 0) return null
                lock.wait(minOf(left, 100))
            }
        }
        return settle(task, explicitFinish = true, expected = expected)
    }
    /** Actual host turn/end, not an inferred idle edge. Keep intent until native calls drain. */
    fun admitEnd(sessionId: String, runId: String, completion: String = "unknown"): Task? = synchronized(lock) {
        val key = Key(sessionId, runId)
        if (!reserve(key)) throw CapacityExceeded()
        if (endedRuns.putIfAbsent(key, completion) != null) return null // First accepted classification is immutable.
        // Unknown ends fence this launch too; a late call cannot reopen them.
        val task = entries[key] ?: return null
        if (task.endRequested) return null
        task.skillScope?.let { skill ->
            skill.endOwner = task.tasks.activeOwner()?.takeIf {
                it.taskId == skill.owner.taskId && it.lifecycle == skill.owner.lifecycle
            }
        }
        task.endRequested = true
        task.completion = completion
        task.ending = true
        lock.notifyAll()
        task
    }

    fun settleEnd(task: Task) {
        task.tasks.cancelPending()
        val original = synchronized(lock) { task.activeWorker }
        original?.interruptCurrent(task.tasks)
        synchronized(lock) { task.ending = false }
        completeEnd(task)
        changed()
    }

    private fun completeEnd(task: Task) = settleInactive(task)

    fun completed(taskId: Long, runId: String, generation: Long): PhoneTasks.Owner? {
        val task = task(taskId) ?: return null
        return synchronized(lock) {
            val owner = task.finished?.takeIf { task.runId == runId && it.lifecycle == generation } ?: return null
            if (task.returnClaimed || lastAdmitted[task.sessionId] !== task || !task.tasks.isCurrent(owner)) return null
            task.returnClaimed = true
            owner
        }
    }

    fun ownerCurrent(taskId: Long, owner: PhoneTasks.Owner): Boolean {
        val task = task(taskId) ?: return false
        return synchronized(lock) { lastAdmitted[task.sessionId] === task } && task.tasks.isCurrent(owner)
    }

    fun stopAll(reason: String) {
        synchronized(lock) { selfCheck?.sealed = true }
        all().forEach { stop(it, reason) }
    }
    fun retire() {
        val workers: List<SerialWorker>
        val old = synchronized(lock) {
            resetting = true
            selfCheck?.sealed = true
            epoch++
            workers = ((entries.values + retiring).mapNotNull { it.backgroundWorker } + mainWorker).distinct()
            entries.values.toList().also { records ->
                for (task in records) {
                    task.skillScope?.cancelled = true
                    task.retired = task.tasks.snapshot()
                    if (!task.resourcesReleased || task.pending > 0 || task.running || task.closing || task.cancelling || task.journalRecord != null) retiring += task
                }
                entries.clear()
                endedRuns.clear()
                retainedRuns.clear()
                stoppedSessions.clear()
                lastAdmitted.clear()
                lock.notifyAll()
            }
        }
        // Never reset the shared legacy lifecycle after exposing its next launch's admission.
        old.forEach { it.tasks.invalidateOwners(); it.tasks.endTask() }
        workers.forEach { it.retire() }
        synchronized(lock) {
            legacy = Task(null, null, legacy.tasks, legacy.core)
            entries[Key(null, null)] = legacy
            resetting = false
            lock.notifyAll()
        }
        // screens still point to old records. Their callbacks only remove their own leases.
        old.forEach(::settleInactive)
        changed()
    }
    /** The union of active records and ended-before-call fences shares one budget. Lock held. */
    private fun reserve(key: Key): Boolean {
        if (key in retainedRuns) return true
        if (retainedRuns.size >= maxRuns) return false
        retainedRuns += key
        return true
    }

    class CapacityExceeded : IllegalStateException(CAPACITY_MESSAGE)

    companion object {
        private const val MAX_APPS_PER_SCOPE = 16
        // An implementation memory bound, not a measured throughput limit. Never evict a fence.
        const val MAX_RUNS_PER_LAUNCH = 256
        // l10n:keep agent lifecycle capacity result
        const val CAPACITY_MESSAGE = "本次引擎保留的手机任务生命周期已达上限，不能安全接收新任务。请重启本地引擎后重试；已有任务仍可结束。"
    }

}
