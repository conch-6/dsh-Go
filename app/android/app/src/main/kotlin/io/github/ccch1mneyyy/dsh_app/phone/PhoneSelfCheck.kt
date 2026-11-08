package io.github.ccch1mneyyy.dsh_app.phone

import android.app.Activity
import android.os.Bundle
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.Profile
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.Reason
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.Stage
import io.github.ccch1mneyyy.dsh_app.phone.PhoneSelfCheckReport.State
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundControl
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundDisplayIo
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundRecoveryProtocol
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundResourceJournal
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundResourceScope
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundReleaseReceipt
import io.github.ccch1mneyyy.dsh_app.phone.background.PrivilegedChannel
import io.github.ccch1mneyyy.dsh_app.phone.background.OwnerScopeProtocol
import io.github.ccch1mneyyy.dsh_app.phone.background.Proto
import io.github.ccch1mneyyy.dsh_app.phone.selfcheck.PhoneSelfCheckTarget
import io.github.ccch1mneyyy.dsh_app.phone.selfcheck.TargetContract
import io.github.ccch1mneyyy.dsh_app.phone.selfcheck.TargetContract.FrameStage
import io.github.ccch1mneyyy.dsh_app.phone.selfcheck.TargetState
import java.util.UUID
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * One local diagnostic, with the same registry and original physical peer as phone tasks.
 * This lock owns only the run/report. Registry, background, UI and physical I/O are all outside it.
 */
internal class PhoneSelfCheck(
    private val sessions: PhoneTaskSessions,
    private val background: BackgroundControl,
    private val clock: () -> Long,
    private val unavailable: () -> Reason?,
    private val prepareReceiver: () -> Boolean,
    private val changed: () -> Unit,
) {
    private class Starting(val client: Any, val live: () -> Boolean) { var cancelled = false }
    private class Run(
        val client: Any,
        val live: () -> Boolean,
        val lease: PhoneTaskSessions.SelfCheckLease,
        val borrow: BackgroundControl.SelfCheckBorrow,
        val profile: Profile,
        val host: () -> Activity?,
        journal: BackgroundResourceJournal,
    ) {
        val handle = UUID.randomUUID().toString()
        val io = BackgroundDisplayIo<PrivilegedChannel>()
        val resource = BackgroundResourceScope(io, journal, if (profile == Profile.PROBE_B) "probe" else "target")
        val report = PhoneSelfCheckReport(profile)
        val targetRun = if (profile != Profile.PROBE_B) UUID.randomUUID().toString() else null
        val target = targetRun?.let { PhoneSelfCheckTarget.prepare(it,
            if (profile == Profile.TARGET_C2) TargetContract.Profile.C2 else TargetContract.Profile.C1) }
        val targetVersionKey = if (profile == Profile.TARGET_C2) Proto.SELF_CHECK_TARGET_C2_VERSION
            else Proto.SELF_CHECK_TARGET_VERSION
        val releaseNonce = if (profile == Profile.TARGET_C2) UUID.randomUUID().toString() else null
        var state = "running"
        var cancelled = false
        var workerActive = true
        var held = true
    }
    private val lock = Any()
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "dsh-phone-selfcheck").apply { isDaemon = true }
    }
    private var starting: Starting? = null
    private var latest: Run? = null

    val needsReceiver: Boolean get() = synchronized(lock) { starting != null || latest?.held == true }

    /** Called by the local main-thread UI entry; reservation and receiver setup do not run a probe. */
    fun start(client: Any, live: () -> Boolean, profile: Profile = Profile.PROBE_B,
              host: () -> Activity? = { null }): Map<String, Any?> {
        unavailable()?.let { return refused(it) }
        val ticket = synchronized(lock) {
            if (!live()) return responseLocked(false, Reason.RETIRED)
            if (starting != null || latest?.held == true) return responseLocked(false, Reason.BUSY)
            Starting(client, live).also { starting = it }
        }
        // Registration is on the existing main-thread entry, before the physical reservation.
        if (!prepareReceiver()) return abandonStart(ticket, Reason.UNAVAILABLE)
        val lease = sessions.tryReserveSelfCheck() ?: return abandonStart(ticket, Reason.BUSY)
        val borrow = background.tryBorrowSelfCheck()
        if (borrow == null) {
            sessions.releaseSelfCheck(lease) // No peer was pinned and no operation was dispatched.
            return abandonStart(ticket, Reason.CHANNEL_UNAVAILABLE)
        }
        val run = Run(client, live, lease, borrow, profile, host, background.resourceJournal)
        val accepted = synchronized(lock) {
            val active = !ticket.cancelled && ticket.live()
            starting = null
            latest = run
            if (!active) { run.cancelled = true; run.state = "cleaning" }
            run.report.update(Stage.DEVICE, State.PASS, true)
            active
        }
        if (!accepted) seal(run)
        worker.execute { if (accepted) execute(run) else cleanup(run) }
        changed()
        return synchronized(lock) { responseLocked(accepted, if (accepted) null else Reason.CANCELLED) }
    }

    private fun abandonStart(ticket: Starting, reason: Reason): Map<String, Any?> {
        val result = synchronized(lock) {
            if (starting === ticket) starting = null
            responseLocked(false, if (ticket.cancelled || !ticket.live()) Reason.CANCELLED else reason)
        }
        changed()
        return result
    }

    fun status(): Map<String, Any?> = synchronized(lock) { responseLocked(true) }
    fun refused(reason: Reason): Map<String, Any?> = synchronized(lock) { responseLocked(false, reason) }

    fun cancel(handle: String): Map<String, Any?> {
        val run = synchronized(lock) {
            val current = latest ?: return responseLocked(false, Reason.UNAVAILABLE)
            if (current.handle != handle) return responseLocked(false, Reason.IDENTITY_CHANGED)
            if (current.held) {
                current.cancelled = true
                if (current.workerActive) current.state = "cleaning"
            }
            current
        }
        if (synchronized(lock) { run.held }) seal(run)
        changed()
        return synchronized(lock) { responseLocked(true) }
    }

    /** Local detach affects only its captured attachment; global stops seal every pending run. */
    fun stop(client: Any? = null) {
        val run = synchronized(lock) {
            starting?.takeIf { client == null || it.client === client }?.cancelled = true
            latest?.takeIf { it.held && (client == null || it.client === client) }?.also {
                it.cancelled = true
                if (it.workerActive) it.state = "cleaning"
            }
        }
        run?.let(::seal)
        changed()
    }

    fun retryCleanup(handle: String): Map<String, Any?> {
        val run = synchronized(lock) {
            val current = latest ?: return responseLocked(false, Reason.UNAVAILABLE)
            if (current.handle != handle) return responseLocked(false, Reason.IDENTITY_CHANGED)
            if (!current.held || current.workerActive || current.state != "cleanup_pending")
                return responseLocked(false, Reason.BUSY)
            current.workerActive = true
            current.state = "cleaning"
            current
        }
        worker.execute { cleanup(run) }
        changed()
        return synchronized(lock) { responseLocked(true) }
    }

    /** Internal recovery consumer, called on the controller's worker with no registry/run/IO lock held. */
    fun retryStoredCleanup(): Boolean {
        val run = synchronized(lock) {
            val original = latest ?: return true
            if (!original.held) return true
            if (original.workerActive || !original.resource.physicalComplete) return false
            original.workerActive = true
            original.state = "cleaning"
            original
        }
        val job = try { worker.submit { cleanup(run) } }
        catch (_: RejectedExecutionException) {
            synchronized(lock) {
                run.workerActive = false
                if (run.held) run.state = "cleanup_pending"
            }
            changed()
            return false
        }
        changed()
        var interrupted = false
        try {
            while (true) {
                try { job.get(); break }
                catch (_: InterruptedException) { interrupted = true }
                catch (_: ExecutionException) {
                    synchronized(lock) {
                        run.workerActive = false
                        if (run.held) run.state = "cleanup_pending"
                    }
                    changed()
                    return false
                }
            }
            return synchronized(lock) { !run.held }
        } finally {
            if (interrupted) Thread.currentThread().interrupt()
        }
    }

    private fun seal(run: Run) {
        run.target?.let(PhoneSelfCheckTarget::seal)
        sessions.sealSelfCheck(run.lease)
        run.io.seal()
    }

    private fun mayStart(run: Run): Boolean =
        synchronized(lock) { latest === run && !run.cancelled && run.live() } &&
            sessions.selfCheckCurrent(run.lease) && background.selfCheckBorrowCurrent(run.borrow) &&
            unavailable() == null

    /** Cancellation and this exact IO submission share the Run monitor; exchange/storage stay outside. */
    private fun admit(run: Run, commit: () -> Unit): Boolean {
        if (!sessions.selfCheckCurrent(run.lease) || !background.selfCheckBorrowCurrent(run.borrow) ||
            unavailable() != null) return false
        return synchronized(lock) {
            if (latest !== run || run.cancelled || !run.live()) false
            else { commit(); true }
        }
    }

    private fun execute(run: Run) {
        if (run.profile != Profile.PROBE_B) { executeTarget(run); return }
        var channelReady = false
        var allocationObserved = false
        var verifyEntered = false
        val startedAt = clock()
        try {
            if (!mayStart(run)) { cancelFromWorker(run); return }
            update(run, Stage.CHANNEL, State.RUNNING, false)
            run.io.call {
                if (!mayStart(run)) { cancelFromWorker(run); return@call }
                val peer = run.borrow.channel
                val probeStarted = clock()
                val cap = peer.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
                if ((cap.get(Proto.OK) as? Boolean) != true) {
                    update(run, Stage.CHANNEL, State.UNKNOWN, false, Reason.CHANNEL_UNAVAILABLE, clock() - probeStarted)
                    return@call
                }
                val birth = BackgroundRecoveryProtocol.birth(cap::get)
                if (!OwnerScopeProtocol.supported(cap) || (cap.get(Proto.SELF_CHECK_PROBE_VERSION) as? Int) != 1 ||
                    (cap.get(Proto.RELEASE_RECEIPT) as? Int) != 1 || birth == null) {
                    update(run, Stage.CHANNEL, State.FAIL, true, Reason.UNSUPPORTED_PEER, clock() - probeStarted)
                    return@call
                }
                channelReady = true
                update(run, Stage.CHANNEL, State.PASS, true, durationMs = clock() - probeStarted)
                if (!mayStart(run)) { cancelFromWorker(run); return@call }
                update(run, Stage.DISPLAY, State.RUNNING, false)
                if (!run.resource.begin(birth)) {
                    update(run, Stage.DISPLAY, State.SKIPPED, false, Reason.UNAVAILABLE)
                    return@call
                }
                if (!mayStart(run)) { cancelFromWorker(run); return@call }
                val allocation = OwnerScopeProtocol.first(run.io, peer,
                    BackgroundRecoveryProtocol.allocate(run.io.owner, "probe", null)) { commit -> admit(run, commit) }
                if (run.io.wasNotAdmitted()) {
                    update(run, Stage.DISPLAY, State.SKIPPED, false, Reason.UNAVAILABLE)
                    return@call
                }
                val id = BackgroundRecoveryProtocol.allocationId(allocation::get)
                if (id == null) {
                    update(run, Stage.DISPLAY, State.UNKNOWN, false, Reason.DEVICE_UNAVAILABLE)
                    return@call
                }
                allocationObserved = true
                if (!run.resource.allocated(id) { mayStart(run) }) {
                    if (!mayStart(run)) cancelFromWorker(run)
                    update(run, Stage.DISPLAY, State.UNKNOWN, true, Reason.UNAVAILABLE)
                    return@call
                }
                if (!mayStart(run)) { cancelFromWorker(run); return@call }
                // Empty allocation is not a Presentation/input result. Only this second op can supply those facts.
                update(run, Stage.INPUT_PROBE, State.RUNNING, false)
                val request = Bundle().apply {
                    putString(Proto.OP, Proto.OP_SELF_CHECK_PROBE)
                    putString(Proto.OWNER, run.io.owner)
                    putInt(Proto.RELEASE_RECEIPT, 1)
                    putInt(Proto.SELF_CHECK_PROBE_VERSION, 1)
                }
                val beginStarted = clock()
                val reply = OwnerScopeProtocol.execute(peer, run.io.owner, request) {
                    check(admit(run) {
                        run.io.checkDispatch()
                        verifyEntered = true
                    })
                }
                synchronized(lock) {
                    run.report.acceptProbe(run.io.owner, reply.get(Proto.OWNER),
                        reply.get(Proto.SELF_CHECK_PROBE_VERSION), reply.get(Proto.OK),
                        reply.get(Proto.SELF_CHECK_DISPLAY_READY), reply.get(Proto.INJECT_OK),
                        reply.get(Proto.ERROR), reply.get(Proto.INJECT_ERROR), clock() - beginStarted)
                }
                changed()
            }
        } catch (_: Exception) {
            synchronized(lock) {
                if (verifyEntered) run.report.unknownProbe(Reason.DEVICE_UNAVAILABLE, clock() - startedAt)
                else if (!channelReady) run.report.update(Stage.CHANNEL, State.UNKNOWN, false,
                    Reason.CHANNEL_UNAVAILABLE, clock() - startedAt)
                else {
                    run.report.update(Stage.DISPLAY, State.UNKNOWN, allocationObserved,
                        Reason.DEVICE_UNAVAILABLE, clock() - startedAt)
                    run.report.update(Stage.INPUT_PROBE, State.NOT_RUN, false, Reason.UNAVAILABLE)
                }
            }
        } finally { cleanup(run) }
    }

    /** Fixed native target only. UI work never occupies the physical I/O lane or registry lock. */
    private fun executeTarget(run: Run) {
        val target = checkNotNull(run.target)
        val targetRun = checkNotNull(run.targetRun)
        var pendingStage = Stage.CHANNEL
        var beganStageAt = clock()
        try {
            if (!mayStart(run)) { cancelFromWorker(run); return }
            update(run, Stage.CHANNEL, State.RUNNING, false)
            val createNonce = UUID.randomUUID().toString()
            val id = run.io.call {
                if (!mayStart(run)) { cancelFromWorker(run); return@call null }
                val peer = run.borrow.channel
                val cap = peer.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
                if ((cap.get(Proto.OK) as? Boolean) != true) {
                    update(run, Stage.CHANNEL, State.UNKNOWN, false, Reason.CHANNEL_UNAVAILABLE,
                        clock() - beganStageAt)
                    return@call null
                }
                val birth = BackgroundRecoveryProtocol.birth(cap::get)
                if (!OwnerScopeProtocol.supported(cap) || (cap.get(run.targetVersionKey) as? Int) != 1 ||
                    (cap.get(Proto.RELEASE_RECEIPT) as? Int) != 1 || birth == null) {
                    update(run, Stage.CHANNEL, State.FAIL, true, Reason.UNSUPPORTED_PEER,
                        clock() - beganStageAt)
                    return@call null
                }
                update(run, Stage.CHANNEL, State.PASS, true, durationMs = clock() - beganStageAt)
                if (!mayStart(run)) { cancelFromWorker(run); return@call null }
                pendingStage = Stage.DISPLAY
                beganStageAt = clock()
                update(run, Stage.DISPLAY, State.RUNNING, false)
                if (!run.resource.begin(birth)) {
                    update(run, Stage.DISPLAY, State.SKIPPED, false, Reason.UNAVAILABLE)
                    return@call null
                }
                val request = targetRequest(run, Proto.OP_SELF_CHECK_TARGET_CREATE, createNonce).apply {
                    putInt(Proto.RELEASE_RECEIPT, 1)
                    putInt(Proto.RESOURCE_RECOVERY_VERSION, 1)
                }
                if (!mayStart(run)) { cancelFromWorker(run); return@call null }
                // Commit this exact request immediately after pin; cancellation cannot leave an unused pin.
                val reply = OwnerScopeProtocol.first(run.io, peer, request) { commit -> admit(run, commit) }
                if (run.io.wasNotAdmitted()) {
                    update(run, Stage.DISPLAY, State.SKIPPED, false, Reason.UNAVAILABLE)
                    return@call null
                }
                val allocatedId = BackgroundRecoveryProtocol.allocationId(reply::get)
                if (allocatedId == null) {
                    update(run, Stage.DISPLAY, State.UNKNOWN, false, Reason.DEVICE_UNAVAILABLE)
                    return@call null
                }
                val observedId = synchronized(lock) {
                    run.report.acceptTargetCreate(run.io.owner, targetRun, createNonce,
                        reply.get(Proto.OWNER), reply.get(Proto.TARGET_RUN), reply.get(Proto.STEP_NONCE),
                        reply.get(run.targetVersionKey), reply.get(Proto.OK), reply.get(Proto.ERROR),
                        reply.get(Proto.SELF_CHECK_DISPLAY_READY), reply.get(Proto.DISPLAY_ID), clock() - beganStageAt,
                        reply.get(Proto.MAIN_VECTOR_RESULT), reply.get(Proto.GLOBAL_FOCUS_RESULT))
                }.also { changed() }
                if (observedId != allocatedId) return@call null
                if (!run.resource.allocated(allocatedId) { mayStart(run) }) {
                    if (!mayStart(run)) cancelFromWorker(run)
                    return@call null
                }
                allocatedId
            } ?: return

            if (!mayStart(run)) { cancelFromWorker(run); return }
            pendingStage = Stage.LAUNCH
            beganStageAt = clock()
            update(run, Stage.LAUNCH, State.RUNNING, false)
            val launched = PhoneSelfCheckTarget.launch(target, id, run.host) { mayStart(run) }
            recordTargetFacts(run, launched)
            if (!mayStart(run)) { cancelFromWorker(run); return }
            if (!launched.created || launched.wrongMain) {
                update(run, Stage.LAUNCH, State.UNKNOWN, launched.launchAttempted,
                    if (launched.wrongMain) Reason.TARGET_WRONG_MAIN
                    else if (!launched.launchAttempted) Reason.TARGET_LAUNCH_DENIED else Reason.TARGET_UNAVAILABLE,
                    clock() - beganStageAt)
                return
            }

            pendingStage = Stage.TREE
            beganStageAt = clock()
            update(run, Stage.TREE, State.RUNNING, false)
            val readNonce = UUID.randomUUID().toString()
            val readRequest = targetRequest(run, Proto.OP_SELF_CHECK_TARGET_READ, readNonce)
            val readReply = run.io.call {
                if (!mayStart(run)) { cancelFromWorker(run); return@call null }
                OwnerScopeProtocol.execute(run.borrow.channel, run.io.owner, readRequest) {
                    check(admit(run) { run.io.checkDispatch() })
                }
            } ?: return
            val ready = synchronized(lock) {
                run.report.acceptTargetRead(run.io.owner, targetRun, readNonce,
                    readReply.get(Proto.OWNER), readReply.get(Proto.TARGET_RUN), readReply.get(Proto.STEP_NONCE),
                    readReply.get(run.targetVersionKey), readReply.get(Proto.OK), readReply.get(Proto.ERROR),
                    readReply.get(Proto.TARGET_MATCHED), readReply.get(Proto.TREE_COMPLETE),
                    readReply.get(Proto.INITIAL_COUNTER_MATCHED), clock() - beganStageAt,
                    readReply.get(Proto.MAIN_VECTOR_RESULT), readReply.get(Proto.GLOBAL_FOCUS_RESULT))
            }
            changed()
            if (!ready) return
            if (!mayStart(run)) { cancelFromWorker(run); return }

            pendingStage = Stage.TAP
            beganStageAt = clock()
            update(run, Stage.TAP, State.RUNNING, false)
            val tapNonce = UUID.randomUUID().toString()
            val tapRequest = targetRequest(run, Proto.OP_SELF_CHECK_TARGET_TAP, tapNonce)
            val tapReply = run.io.call {
                if (!mayStart(run)) { cancelFromWorker(run); return@call null }
                OwnerScopeProtocol.execute(run.borrow.channel, run.io.owner, tapRequest) {
                    check(admit(run) { run.io.checkDispatch() })
                }
            } ?: return
            val tapped = synchronized(lock) {
                run.report.acceptTargetTap(run.io.owner, targetRun, tapNonce,
                    tapReply.get(Proto.OWNER), tapReply.get(Proto.TARGET_RUN), tapReply.get(Proto.STEP_NONCE),
                    tapReply.get(run.targetVersionKey), tapReply.get(Proto.OK), tapReply.get(Proto.ERROR),
                    tapReply.get(Proto.ACTION_ATTEMPTED), tapReply.get(Proto.TARGET_MATCHED),
                    tapReply.get(Proto.TREE_COMPLETE), tapReply.get(Proto.COUNTER_MATCHED), clock() - beganStageAt)
            }
            changed()
            if (!tapped || run.profile != Profile.TARGET_C2) return

            for ((stage, op) in listOf(Stage.TEXT_ASCII to Proto.OP_SELF_CHECK_TARGET_TEXT_ASCII,
                    Stage.TEXT_ZH to Proto.OP_SELF_CHECK_TARGET_TEXT_ZH)) {
                if (!mayStart(run)) { cancelFromWorker(run); return }
                pendingStage = stage
                beganStageAt = clock()
                update(run, stage, State.RUNNING, false)
                val nonce = UUID.randomUUID().toString()
                val request = targetRequest(run, op, nonce)
                val reply = run.io.call {
                    if (!mayStart(run)) { cancelFromWorker(run); return@call null }
                    OwnerScopeProtocol.execute(run.borrow.channel, run.io.owner, request) {
                        check(admit(run) { run.io.checkDispatch() })
                    }
                } ?: return
                val matched = synchronized(lock) {
                    run.report.acceptTargetText(stage, run.io.owner, targetRun, nonce,
                        reply.get(Proto.OWNER), reply.get(Proto.TARGET_RUN), reply.get(Proto.STEP_NONCE),
                        reply.get(run.targetVersionKey), reply.get(Proto.OK), reply.get(Proto.ERROR),
                        reply.get(Proto.ACTION_ATTEMPTED), reply.get(Proto.ACCEPTED), reply.get(Proto.TARGET_MATCHED),
                        reply.get(Proto.TREE_COMPLETE), reply.get(Proto.TEXT_MATCHED), clock() - beganStageAt,
                        reply.get(Proto.MAIN_VECTOR_RESULT), reply.get(Proto.GLOBAL_FOCUS_RESULT))
                }
                changed()
                if (!matched) return
            }

            var continuityStarted = 0L
            for (frame in FrameStage.entries) {
                if (!mayStart(run)) { cancelFromWorker(run); return }
                val continuity = frame != FrameStage.CAPTURE
                if (frame == FrameStage.CONTINUITY_FIRST) continuityStarted = clock()
                pendingStage = if (continuity) Stage.CONTINUITY else Stage.CAPTURE
                beganStageAt = if (continuity) continuityStarted else clock()
                if (continuity && clock() - continuityStarted >= CONTINUITY_BUDGET_MS) {
                    update(run, Stage.CONTINUITY, State.UNKNOWN, frame != FrameStage.CONTINUITY_FIRST,
                        Reason.TARGET_CONTINUITY_UNCONFIRMED,
                        clock() - beganStageAt)
                    return
                }
                if (!continuity || frame == FrameStage.CONTINUITY_FIRST)
                    update(run, pendingStage, State.RUNNING, false)
                // The previous exact pixel ACK is accepted before this fixed next phase can exist.
                if (!PhoneSelfCheckTarget.advance(target, frame)) {
                    update(run, pendingStage, State.UNKNOWN, false, Reason.TARGET_FRAME_UNAVAILABLE,
                        clock() - beganStageAt)
                    return
                }
                val nonce = UUID.randomUUID().toString()
                val request = targetRequest(run, if (continuity) Proto.OP_SELF_CHECK_TARGET_CONTINUITY
                    else Proto.OP_SELF_CHECK_TARGET_CAPTURE, nonce)
                val reply = run.io.call {
                    if (!mayStart(run)) { cancelFromWorker(run); return@call null }
                    if (continuity && clock() - continuityStarted >= CONTINUITY_BUDGET_MS) {
                        update(run, Stage.CONTINUITY, State.UNKNOWN, frame != FrameStage.CONTINUITY_FIRST,
                            Reason.TARGET_CONTINUITY_UNCONFIRMED, clock() - beganStageAt)
                        return@call null
                    }
                    OwnerScopeProtocol.execute(run.borrow.channel, run.io.owner, request) {
                        check(admit(run) { run.io.checkDispatch() })
                    }
                } ?: return
                val matched = synchronized(lock) {
                    run.report.acceptTargetFrame(frame, run.io.owner, targetRun, nonce,
                        reply.get(Proto.OWNER), reply.get(Proto.TARGET_RUN), reply.get(Proto.STEP_NONCE),
                        reply.get(run.targetVersionKey), reply.get(Proto.OK), reply.get(Proto.ERROR),
                        reply.get(Proto.TARGET_MATCHED), reply.get(Proto.TREE_COMPLETE),
                        reply.get(Proto.FRAME_MATCHED), clock() - beganStageAt)
                }
                changed()
                if (!matched) return
            }
        } catch (_: Exception) {
            synchronized(lock) {
                val reason = if (pendingStage == Stage.CHANNEL) Reason.CHANNEL_UNAVAILABLE else Reason.DEVICE_UNAVAILABLE
                if (pendingStage == Stage.TREE) run.report.unknownTargetRead(reason, clock() - beganStageAt)
                else run.report.update(pendingStage, State.UNKNOWN, false, reason, clock() - beganStageAt)
            }
        } finally { cleanup(run) }
    }

    private fun targetRequest(run: Run, op: String, nonce: String): Bundle = Bundle().apply {
        putString(Proto.OP, op)
        putString(Proto.OWNER, run.io.owner)
        putInt(run.targetVersionKey, 1)
        putString(Proto.TARGET_RUN, checkNotNull(run.targetRun))
        putString(Proto.STEP_NONCE, nonce)
    }

    private fun recordTargetFacts(run: Run, facts: TargetState.Facts) {
        if (facts.wrongMain) update(run, Stage.MAIN, State.FAIL, true, Reason.TARGET_WRONG_MAIN)
    }

    private fun cancelFromWorker(run: Run) {
        synchronized(lock) { run.cancelled = true; run.state = "cleaning" }
        seal(run)
    }

    private fun cleanup(run: Run) {
        seal(run)
        synchronized(lock) {
            run.state = "cleaning"
            run.report.finishPending(run.cancelled || !run.live())
            run.report.update(Stage.CLEANUP, State.RUNNING, false)
        }
        changed()
        val startedAt = clock()
        // A pending Android launch/target must be sealed and truly closed before the VD can go away.
        val targetClosed = if (run.resource.physicalComplete) true else run.target?.let { target ->
            try { PhoneSelfCheckTarget.close(target).also { recordTargetFacts(run, it) }.closed }
            catch (_: Exception) {
                recordTargetFacts(run, PhoneSelfCheckTarget.snapshot(target))
                false
            }
        } ?: true
        val cleaned = targetClosed && try {
            run.resource.cleanup { peer ->
                val reply = OwnerScopeProtocol.execute(peer, run.io.owner, Bundle().apply {
                    putString(Proto.OP, Proto.OP_RELEASE)
                    putString(Proto.OWNER, run.io.owner)
                    putInt(Proto.RELEASE_RECEIPT, 1)
                    if (run.profile == Profile.TARGET_C2) {
                        putInt(Proto.SELF_CHECK_TARGET_C2_VERSION, 1)
                        putInt(Proto.SELF_CHECK_FINAL_MAIN, 1)
                        putString(Proto.TARGET_RUN, checkNotNull(run.targetRun))
                        putString(Proto.RELEASE_NONCE, checkNotNull(run.releaseNonce))
                    }
                })
                val released = BackgroundReleaseReceipt.accepts(run.io.owner, reply.get(Proto.RELEASE_RECEIPT),
                    reply.get(Proto.OWNER), reply.get(Proto.OK), reply.get("released"),
                    reply.get(Proto.TASK_SCOPE_EMPTY), reply.get("neverCreated"))
                if (released && run.profile == Profile.TARGET_C2) {
                    // Measurement decode failure cannot retract an already valid physical receipt.
                    try {
                        synchronized(lock) {
                            run.report.acceptFinalMain(run.io.owner, checkNotNull(run.targetRun),
                                checkNotNull(run.releaseNonce), reply.get(Proto.OWNER), reply.get(Proto.TARGET_RUN),
                                reply.get(Proto.RELEASE_NONCE), reply.get(Proto.SELF_CHECK_TARGET_C2_VERSION),
                                reply.get(Proto.OK), reply.get(Proto.ERROR),
                                reply.get(Proto.FINAL_MAIN_VECTOR), reply.get(Proto.FINAL_GLOBAL_FOCUS))
                        }
                    } catch (_: Exception) {
                        synchronized(lock) { run.report.acceptFinalMain(run.io.owner,
                            checkNotNull(run.targetRun), checkNotNull(run.releaseNonce)) }
                    }
                }
                released
            }
        } catch (_: Exception) { false }
        // Resource completion, return of the original borrow, then registry release, in that order.
        val returned = cleaned && background.releaseSelfCheckBorrow(run.borrow)
        val completed = returned && sessions.releaseSelfCheck(run.lease)
        val unused = run.io.peer() == null || run.io.wasNotAdmitted()
        synchronized(lock) {
            run.workerActive = false
            if (completed) {
                run.held = false
                run.state = if (run.cancelled || !run.live()) "cancelled" else "done"
                run.report.update(Stage.CLEANUP, if (unused) State.SKIPPED else State.PASS,
                    !unused, if (unused) Reason.UNAVAILABLE else null,
                    durationMs = clock() - startedAt)
            } else {
                run.state = "cleanup_pending"
                if (run.resource.physicalComplete) {
                    // A failed durable delete cannot retract this original physical receipt.
                    run.report.update(Stage.CLEANUP, if (unused) State.SKIPPED else State.PASS,
                        !unused, if (unused) Reason.UNAVAILABLE else null,
                        durationMs = clock() - startedAt)
                } else run.report.update(Stage.CLEANUP, State.UNKNOWN, false,
                    if (targetClosed) Reason.CLEANUP_FAILED else Reason.TARGET_CLEANUP_PENDING, clock() - startedAt)
            }
        }
        changed()
    }

    private companion object { const val CONTINUITY_BUDGET_MS = 10_000L }

    private fun update(run: Run, stage: Stage, state: State, observed: Boolean,
                       reason: Reason? = null, durationMs: Long? = null) {
        synchronized(lock) { run.report.update(stage, state, observed, reason, durationMs) }
        changed()
    }

    private fun responseLocked(accepted: Boolean, reason: Reason? = null): Map<String, Any?> {
        val current = latest
        return linkedMapOf<String, Any?>(
            "v" to 1, "accepted" to accepted, "state" to (current?.state ?: "idle"),
            "profile" to (current?.profile ?: Profile.PROBE_B).wire,
            "coverage" to "partial", "steps" to (current?.report ?: PhoneSelfCheckReport()).toMaps(),
        ).apply {
            current?.let { put("runHandle", it.handle) }
            reason?.let { put("reason", it.wire) }
        }
    }
}
