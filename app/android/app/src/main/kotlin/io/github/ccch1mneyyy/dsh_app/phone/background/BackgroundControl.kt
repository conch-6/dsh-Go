package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.provider.Settings
import io.github.ccch1mneyyy.dsh_app.phone.PhoneControl
import io.github.ccch1mneyyy.dsh_app.phone.PhoneAppIdentity
import io.github.ccch1mneyyy.dsh_app.phone.a11y.MlKitLocalOcr
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.FutureTask
import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks

/**
 * The 不打扰模式 surface the core's `PhonePlugin` calls into: the `background` block of `status`,
 * and the actions behind `setBackgroundMode`, `requestShizukuPermission`, `adbStartPairing`,
 * `adbPair`, `adbConnect`. It owns the shared Shizuku/Sui, self-ADB and explicit root starters,
 * probes whether a trusted virtual display and input injection work here, and retains
 * the original task's [BackgroundDisplay] until its strict cleanup succeeds. Method names match the
 * `dsh/phone` channel.
 */
class BackgroundControl private constructor(context: Context) {
    private val app = context.applicationContext

    @Volatile var onStatusChanged: () -> Unit = {}

    private val keepGuard = Any()
    private var transportUsers = 0
    internal class SelfCheckBorrow internal constructor(
        val channel: PrivilegedChannel,
        internal val selection: PrivilegedKeepState.Ticket,
    ) {
        internal var returned = false
    }
    @Volatile private var selfCheckBorrow: SelfCheckBorrow? = null
    @Volatile private var gateCall: BackgroundGateCall<PrivilegedChannel>? = null

    // These reservations cover actual setup/gate/grant bodies, including their cleanup finally.
    private fun beginTransportUse(recoveryUse: Boolean = false): Boolean = synchronized(keepGuard) {
        if (resourceMaintenance != null || !recoveryUse && retiredResourcePeer != null ||
            selfCheckBorrow != null || gateCall != null || selectingResource || interruptRequested) false
        else { transportUsers++; true }
    }
    private fun endTransportUse() {
        synchronized(keepGuard) { check(transportUsers > 0); transportUsers-- }
        finishInterrupt()
    }

    /** Capture only an already-published peer; this never connects or restores consent. */
    internal fun tryBorrowSelfCheck(): SelfCheckBorrow? {
        if (resourceAdmission() != null) return null
        val borrowed = synchronized(this) {
            synchronized(keepGuard) {
                if (resourceMaintenance != null || retiredResourcePeer != null || taskResource.occupied || selectingResource || interruptRequested || interruptFinishing ||
                    selfCheckBorrow != null || gateCall != null || gate.needsRetest || transportUsers != 0 || restoring != null || selectionChange != null) return null
                val current = channel ?: return null
                if (mode !in PrivilegedKeepState.MODES) return null
                SelfCheckBorrow(current, keep.selectionTicket()).also { selfCheckBorrow = it }
            }
        }
        // Starter identity is checked outside controller locks; the reservation blocks new setup.
        val published = when (borrowed.selection.mode) {
            "root" -> root.isPublished(borrowed.channel)
            "adb" -> adb.isPublished(borrowed.channel)
            "shizuku", "sui" -> shizuku.isPublished(borrowed.channel)
            else -> false
        }
        if (!published || !selfCheckBorrowCurrent(borrowed)) {
            synchronized(keepGuard) {
                if (selfCheckBorrow === borrowed) {
                    borrowed.returned = true
                    selfCheckBorrow = null
                }
            }
            // Start may run on main. Failed local reservation must never disconnect there.
            recovery.execute { finishInterrupt() }
            return null
        }
        return borrowed
    }

    internal fun selfCheckBorrowCurrent(borrowed: SelfCheckBorrow): Boolean = synchronized(keepGuard) {
        selfCheckBorrow === borrowed && !interruptRequested && keep.selectionCurrent(borrowed.selection)
    }

    /** Coordinator worker only; still holds its registry reservation during pending disconnect. */
    internal fun releaseSelfCheckBorrow(borrowed: SelfCheckBorrow): Boolean {
        val released = synchronized(keepGuard) {
            if (borrowed.returned) true
            else if (selfCheckBorrow !== borrowed) false
            else { borrowed.returned = true; selfCheckBorrow = null; true }
        }
        // Strict resource cleanup is already complete. A disconnect failure keeps the existing
        // interrupt gate closed; it must not turn a returned borrow into an unretryable false result.
        if (released) runCatching { finishInterrupt() }
        return released
    }

    private fun transportBusy(): Map<String, Any?> = mapOf("ok" to false,
        "reason" to AppStrings.get(app, R.string.phone_background_cleanup_busy))
    private val preferenceGuard = Any()
    private val viewportPrefs = app.getSharedPreferences("phone-background-viewport", Context.MODE_PRIVATE)
    @Volatile private var viewport = BackgroundPolicy.Viewport.parse(
        runCatching { viewportPrefs.getString("preset", "portrait") }.getOrNull()) ?: BackgroundPolicy.Viewport.PORTRAIT
    private val parallelPrefs = app.getSharedPreferences("phone-background-parallelism", Context.MODE_PRIVATE)
    @Volatile private var parallelLimit = parallelPrefs.getInt("limit", 1)
    @Volatile private var selectionChange: Any? = null
    private val keepPrefs = app.getSharedPreferences("phone-privileged-keep", Context.MODE_PRIVATE)
    private val keep = PrivilegedKeepState(keepPrefs.getString("keptMode", "off") ?: "off",
        PhoneControl.switchedOn(app), Build.VERSION.SDK_INT >= BackgroundPolicy.MIN_SDK)
    private val recovery = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-privileged-keep").apply { isDaemon = true } }
    // Pairing from the App and from the notification share one queue: an older attempt can't
    // stop a newer one's discovery, and its result can't replace the newer one's notification.
    private val pairing = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-adb-pair").apply { isDaemon = true } }
    @Volatile private var restoring: FutureTask<PrivilegedChannel?>? = null
    private var restoringTicket: PrivilegedKeepState.Ticket? = null
    private var restoreAgain = false
    private val networkGuard = Any()
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    // Null capabilities mean not probed; only an actual failed attempt records a transport error.
    private val gate = BackgroundGateState()
    private val shizuku = ShizukuStarter(app, {
        synchronized(keepGuard) { if (mode == "shizuku" || mode == "sui") gate.reset() }
    }) { transportChanged("sharedApi") }
    private val adb = AdbStarter(app) { transportChanged("adb") }
    private val root = RootStarter(app) { transportChanged("root") }

    private val mode: String get() = keep.mode
    @Volatile private var rootSelected = mode == "root"
    @Volatile private var channel: PrivilegedChannel? = null
    private val taskResource = BackgroundTaskSlot<BackgroundDisplay, PrivilegedChannel>(this)
    // Lock order: this -> keepGuard -> previewGuard (either prefix may be omitted). Never IPC or a reverse lock under previewGuard.
    private val previewGuard = Any()
    @Volatile private var previewTargets = emptyMap<Long, BackgroundPreviewTarget>()
    @Volatile var onPreviewChanged: () -> Unit = {}
    @Volatile internal var localOcrAllowed: (PhoneAppIdentity) -> Boolean = { false }

    fun previewTarget(taskId: Long): BackgroundPreviewTarget? = previewTargets[taskId]

    /** Memory publication only; callers notify after releasing controller locks. */
    private fun replaceChannel(value: PrivilegedChannel?): Boolean = synchronized(previewGuard) {
        if (channel === value) false else {
            channel = value
            previewTargets = emptyMap()
            true
        }
    }

    /** Ready belongs to its original record; it does not select a preview consumer. */
    private fun publishPreviewTarget(record: BackgroundTaskSlot.TaskResource<BackgroundDisplay, PrivilegedChannel>,
                                     value: PrivilegedChannel) {
        val changed = synchronized(this) {
            synchronized(previewGuard) {
                val active = record.driver
                val taskId = record.owner.taskId
                if (!taskResource.current(record) || channel !== value || value.backgroundLimit == 0 || !active.previewAvailable(value)) false
                else if (previewTargets[taskId]?.let { it.driver === active && it.channel === value } == true) false
                else {
                    previewTargets = previewTargets + (taskId to BackgroundPreviewTarget(taskId, active.ownerToken, value, active))
                    true
                }
            }
        }
        if (changed) onPreviewChanged()
    }

    /** Called after sealing dispatch; no callback or platform work here. */
    private fun withdrawPreviewTarget(value: BackgroundDisplay): Boolean = synchronized(previewGuard) {
        val old = previewTargets.entries.firstOrNull { it.value.driver === value } ?: return false
        previewTargets = previewTargets - old.key
        true
    }
    @Volatile private var interruptRequested = false
    @Volatile private var selectingResource = false
    private var interruptFinishing = false
    private var interruptStopping = false

    internal val resourceJournal = BackgroundResourceJournal(
        read = { app.getSharedPreferences("phone-background-resources", Context.MODE_PRIVATE).getString("journal", null) },
        commit = { value -> app.getSharedPreferences("phone-background-resources", Context.MODE_PRIVATE)
            .edit().putString("journal", value).commit() },
    )
    private class RetiredResourcePeer(val peer: PrivilegedChannel, val identity: String, val selection: PrivilegedKeepState.Ticket)
    @Volatile private var resourceMaintenance: Any? = null
    @Volatile private var retiredResourcePeer: RetiredResourcePeer? = null

    init { recovery.execute { resourceJournal.load(); notifyChanged() } }

    /** Memory-only, shared by real MCP admission and new physical resource entry points. */
    internal fun resourceAdmission(): String? {
        val state = resourceJournal.status().state
        return if (state != "clear" || resourceMaintenance != null || retiredResourcePeer != null)
            BackgroundResourceJournal.REFUSAL else null
    }

    private fun resourceRecoveryStatus(): Map<String, Any?> {
        val saved = resourceJournal.status()
        val running = resourceMaintenance != null
        return resourceRecoveryStatus(saved, running, retiredResourcePeer != null, lostTaskId() != null,
            mode in PrivilegedKeepState.MODES && (channel?.alive() == true || keep.enabled))
    }

    /** IDs come from still-retained originals, never from a journal string. */
    internal fun pendingStoredTaskIds(): List<Long> = taskResource.cleanupCandidates()
        .filter { it.driver.physicalComplete }.map { it.owner.taskId }

    /** Sealed originals whose pinned peer died; liveness is read outside the slot monitor. */
    private fun lostTaskResources(): List<BackgroundTaskSlot.TaskResource<BackgroundDisplay, PrivilegedChannel>> =
        taskResource.cleanupCandidates().filter { !it.driver.physicalComplete && it.driver.originalPeerLost }
    internal fun lostTaskId(): Long? = lostTaskResources().firstOrNull()?.owner?.taskId

    /** Only a pure memory intent change belongs here; transport, callbacks and disk stay outside. */
    internal fun <T> changeGateIntent(change: () -> T): T {
        val original = gateCall
        val result = gate.changeIntent(change)
        if (original != null && !gate.current(original.probe)) original.io.seal()
        return result
    }

    internal fun retryStoredGateCleanup(): Boolean {
        val old = gateCall ?: return true
        // A drained dead pin needs the following explicit recovery stage, not a storage-only retry.
        if (!old.resource.physicalComplete) return old.recoveryPending() && !old.peer.alive()
        return retryGateCleanup(old.handle)["ok"] == true
    }

    /** Existing control executor caller waits outside every controller/registry/Tasks lock. */
    fun retryBackgroundRecovery(): Map<String, Any?> {
        val future = FutureTask<String?> {
            if (!resourceJournal.retryStorage()) "storageUnavailable" else retryResourceRecoveryNow()
        }
        recovery.execute(future)
        var interrupted = false
        var reason: String? = "recoveryUnknown"
        try {
            while (true) {
                try { reason = future.get(); break }
                catch (_: InterruptedException) { interrupted = true }
                catch (_: Exception) { reason = "recoveryUnknown"; break }
            }
        } finally { if (interrupted) Thread.currentThread().interrupt() }
        notifyChanged()
        return mapOf("ok" to (reason == null), "reason" to reason)
    }

    private fun retryResourceRecoveryNow(): String? {
        val records = resourceJournal.oldRecords() ?: return "storageUnavailable"
        val lost = lostTaskResources()
        val lostGate = gateCall?.takeIf { it.recoveryPending() && !it.peer.alive() && !it.resource.physicalComplete }
        if (lost.isNotEmpty()) {
            for (original in lost) recoverOriginalResource(original, null)?.let { return it }
            return null
        }
        if (lostGate != null) return recoverOriginalResource(null, lostGate)
        if (records.isEmpty() && retiredResourcePeer == null) return null // Storage retry only; never retires a live current peer.
        if (!beginTransportUse(recoveryUse = true)) return "busy"
        try {
            val selection = synchronized(keepGuard) { keep.selectionTicket() }
            val pending = retiredResourcePeer
            val allowed = { !interruptRequested && selectionChange == null && keep.selectionCurrent(selection) }
            // A retained completed peer can be disconnected without reviving the old user's consent.
            val peer = pending?.peer ?: activeChannel(allowed, explicit = true, transportReserved = true)
                ?: return "connectionRequired"
            return recoverResourceRecords(peer, selection, allowed, settingsUse = false)
        } finally {
            endTransportUse()
            if (keep.enabled) restoreKeptChannel()
        }
    }

    /** This reservation only admits a check of the retained original. It never reopens dispatch. */
    private fun recoverOriginalResource(
        lost: BackgroundTaskSlot.TaskResource<BackgroundDisplay, PrivilegedChannel>?,
        lostGate: BackgroundGateCall<PrivilegedChannel>?,
    ): String? {
        val selection: PrivilegedKeepState.Ticket
        val ticket = synchronized(this) {
            synchronized(keepGuard) {
                if (resourceMaintenance != null || retiredResourcePeer != null || selfCheckBorrow != null ||
                    transportUsers != 0 || restoring != null || selectionChange != null ||
                    selectingResource || interruptFinishing) return "busy"
                if (lost != null) {
                    if (taskResource.cleanupCandidates().none { it === lost } || gateCall != null) return "busy"
                } else {
                    if (lostGate == null || gateCall !== lostGate || !lostGate.recoveryPending() || taskResource.occupied) return "busy"
                }
                selection = keep.selectionTicket()
                Any().also { resourceMaintenance = it }
            }
        }
        // Starter/transport admission callbacks must not acquire ownership locks.
        val allowed = {
            resourceMaintenance === ticket && selectionChange == null && keep.selectionCurrent(selection) &&
                (lost == null || !lost.driver.physicalComplete) &&
                (lostGate == null || gateCall === lostGate && !lostGate.resource.physicalComplete)
        }
        notifyChanged()
        try {
            val peer = activeChannel(allowed, explicit = true, transportReserved = true, recoveryOnly = true)
                ?: return "connectionRequired"
            if (lost != null) return recoverLostTask(lost.driver, peer, allowed)
            val call = checkNotNull(lostGate)
            val released = call.retryRecovery({ !it.alive() }) { saved -> verifyLostResource(saved, peer, allowed) }
            return if (finishGateCall(call, released)) null else "recoveryUnknown"
        } finally {
            synchronized(keepGuard) { if (resourceMaintenance === ticket) resourceMaintenance = null }
            notifyChanged()
            finishInterrupt()
        }
    }

    private fun verifyLostResource(saved: BackgroundResourceJournal.Record, peer: PrivilegedChannel,
                                   mayStart: () -> Boolean): Boolean {
        val cap = peer.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) }) {
            check(mayStart()) { "selectionChanged" }
        }
        val birth = if ((cap.get(Proto.OK) as? Boolean) == true) BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey) else null
        if (birth == null || saved.birth.peer == birth.peer || !mayStart()) return false
        val reply = peer.execute(BackgroundRecoveryProtocol.check(saved)) { check(mayStart()) { "selectionChanged" } }
        return BackgroundRecoveryProtocol.recovered(saved, reply::get, reply::containsKey)
    }

    /** The sealed slot stays the fence. Only a different peer's exact absence receipt completes the
     * drained original scope; endTask then returns the slot and registry leases by the normal path.
     */
    private fun recoverLostTask(lost: BackgroundDisplay, peer: PrivilegedChannel, mayStart: () -> Boolean): String? = try {
        val verified = lost.recoverLostPeer { saved -> verifyLostResource(saved, peer, mayStart) }
        // A completed physical proof whose durable clear failed is retried by endTask.
        if (verified || lost.physicalComplete) null else "recoveryUnknown"
    } catch (_: Exception) { "recoveryUnknown" }

    private fun recoverResourceRecords(peer: PrivilegedChannel, selection: PrivilegedKeepState.Ticket,
                                       mayStart: () -> Boolean, settingsUse: Boolean): String? {
        if (!resourceJournal.retryStorage()) return "storageUnavailable"
        val originals = resourceJournal.oldRecords() ?: return "storageUnavailable"
        if (originals.isEmpty() && retiredResourcePeer == null) return null
        val ticket = synchronized(this) {
            synchronized(keepGuard) {
                if (resourceMaintenance != null || taskResource.occupied || selfCheckBorrow != null || gateCall != null ||
                    transportUsers != 1 || restoring != null || selectionChange != null || interruptFinishing ||
                    selectingResource != settingsUse) return "busy"
                Any().also { resourceMaintenance = it }
            }
        }
        notifyChanged()
        try {
            // Reservation now prevents new record producers; storage is never read under its lock.
            if (resourceJournal.hasCurrentResources()) return "busy"
            retiredResourcePeer?.let { retired ->
                if (!finishRetiredResourcePeer(retired)) return "storageUnavailable"
                return if (resourceJournal.oldRecords()?.isEmpty() == true) null else "connectionRequired"
            }
            if (!mayStart()) return "selectionChanged"
            val cap = peer.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) }) {
                check(mayStart()) { "selectionChanged" }
            }
            if ((cap.get(Proto.OK) as? Boolean) != true) return "connectionRequired"
            val birth = BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey) ?: return "recoveryUnsupported"
            for ((oldPeer, group) in originals.groupBy { it.birth.peer }) {
                if (!mayStart()) return "selectionChanged"
                if (birth.peer == oldPeer) {
                    if (group.any { it.birth != birth }) return "recoveryUnknown"
                    val reply = peer.execute(BackgroundRecoveryProtocol.retire(oldPeer)) {
                        check(mayStart()) { "selectionChanged" }
                    }
                    if (!BackgroundRecoveryProtocol.retired(oldPeer, reply::get)) return "recoveryUnknown"
                    val retired = RetiredResourcePeer(peer, oldPeer, selection)
                    retiredResourcePeer = retired
                    if (!resourceJournal.recoveredPeer(oldPeer, group)) return "storageUnavailable"
                    if (!finishRetiredResourcePeer(retired)) return "storageUnavailable"
                    // This connection is now retired. Do not send checks for another group on it.
                    return if (resourceJournal.oldRecords()?.isEmpty() == true) null else "connectionRequired"
                }
                for (record in group) {
                    if (!mayStart()) return "selectionChanged"
                    val reply = peer.execute(BackgroundRecoveryProtocol.check(record)) {
                        check(mayStart()) { "selectionChanged" }
                    }
                    if (!BackgroundRecoveryProtocol.recovered(record, reply::get, reply::containsKey))
                        return "recoveryUnknown"
                    if (!resourceJournal.recovered(record)) return "storageUnavailable"
                }
            }
            return null
        } catch (_: Exception) {
            return "recoveryUnknown"
        } finally {
            synchronized(keepGuard) { if (resourceMaintenance === ticket) resourceMaintenance = null }
            notifyChanged()
            finishInterrupt()
        }
    }

    /** All old scopes have receipts AND their records are durably gone before transport teardown. */
    private fun finishRetiredResourcePeer(retired: RetiredResourcePeer): Boolean {
        val left = resourceJournal.oldRecords() ?: return false
        if (left.any { it.birth.peer == retired.identity }) return false
        if (retiredResourcePeer !== retired) return false
        val previewChanged = synchronized(keepGuard) {
            gate.requireRetest()
            synchronized(previewGuard) {
                if (channel !== retired.peer) false
                else { channel = null; previewTargets = emptyMap(); true }
            }
        }
        if (previewChanged) onPreviewChanged()
        // The maintenance reservation forbids a new starter borrower while the original family closes.
        val family = if (retired.selection.mode == "sui") "shizuku" else retired.selection.mode
        disconnectTransports { it == family }
        retired.peer.close()
        if (retiredResourcePeer === retired) retiredResourcePeer = null
        return true
    }


    private fun notifyChanged() = runCatching { onStatusChanged() }

    private fun androidOk(): Boolean = Build.VERSION.SDK_INT >= BackgroundPolicy.MIN_SDK

    // ---- status ------------------------------------------------------------

    /** Last accepted gate facts only: no connection, permission query or fresh self-test. */
    fun inputProbeDiagnostics(): Map<String, Any?> = InputProbeDiagnostics.snapshot(gate.snapshot)

    /** The `background` sub-map of the `dsh/phone` `status` method. */
    fun status(): Map<String, Any?> {
        val reason = readiness()
        val shizukuStatus = shizuku.status()
        val adbStatus = adb.status()
        val rootStatus = root.status()
        val cached = gate.snapshot
        return mapOf(
            "mode" to PrivilegedPathPolicy.legacyMode(mode),
            "ready" to PrivilegedPathPolicy.legacyReady(mode, reason == null),
            "reason" to PrivilegedPathPolicy.legacyReason(
                mode, reason, AppStrings.get(app, R.string.background_root_legacy_client),
            ),
            "androidOk" to androidOk(),
            "viewport" to mapOf("v" to 1, "preset" to viewport.preset),
            "trustedDisplay" to cached.trustedDisplayOk,
            "inject" to cached.injectOk,
            "gateCleanup" to gateCleanupStatus(),
            "resourceRecovery" to resourceRecoveryStatus(),
            "shizuku" to shizukuStatus.map(),
            "adb" to adbStatus.map(),
            "root" to rootStatus.map(),
            "privileged" to mapOf(
                "v" to 1,
                "mode" to mode,
                "ready" to (reason == null),
                "reason" to reason,
                "supportedModes" to PrivilegedPathPolicy.modes,
                "recommendedMode" to PrivilegedPathPolicy.recommended(
                    mode, reason == null, androidOk(), shizukuStatus.provider,
                    shizukuStatus.running, shizukuStatus.granted, rootSelected,
                    rootStatus.connected, adbStatus.paired, adbStatus.wirelessDebugging,
                ),
                "grantPath" to SecureSettingsGrant.privilegedPath(
                    secureSettingsGranted(), shizukuStatus, adbStatus, rootSelected, rootStatus.connected,
                ),
                "rootSelected" to rootSelected,
                "keep" to keep.map(channel?.alive() == true),
            ),
        )
    }

    private val UNSUPPORTED: String get() = AppStrings.get(app, R.string.background_unsupported)

    private fun gateCleanupStatus(): Map<String, Any?> {
        val current = gateCall ?: return mapOf("v" to 1, "state" to "idle", "canRetry" to false, "handle" to null)
        return current.status()
    }

    private fun readiness(): String? = when {
        resourceAdmission() != null -> AppStrings.get(app, R.string.background_resource_recovery_pending)
        gateCall != null -> AppStrings.get(app, R.string.background_gate_cleanup_pending)
        selectingResource -> AppStrings.get(app, R.string.background_gate_checking)
        mode == "off" -> AppStrings.get(app, R.string.background_off)
        gate.needsRetest -> AppStrings.get(app, R.string.background_gate_retest)
        !androidOk() -> AppStrings.get(app, R.string.background_requires_android)
        mode == "shizuku" || mode == "sui" -> shizuku.reason() ?: run {
            val provider = shizuku.status().provider
            if (provider == mode) gateReason() else when (provider) {
                ShizukuStatus.SUI -> AppStrings.get(app, R.string.background_provider_mismatch, "Shizuku", "Sui")
                ShizukuStatus.SHIZUKU -> AppStrings.get(app, R.string.background_provider_mismatch, "Sui", "Shizuku")
                else -> AppStrings.get(app, R.string.background_not_ready)
            }
        }
        mode == "root" -> rootReason() ?: gateReason()
        mode == "adb" -> adb.reason() ?: gateReason()
        else -> AppStrings.get(app, R.string.background_unknown_mode)
    }

    private fun gateReason(): String? {
        if (keep.connectionUnavailable(channel?.alive() == true)) {
            return AppStrings.get(app, R.string.background_not_ready)
        }
        val cached = gate.snapshot
        return when {
            cached.connectionError != null -> AppStrings.get(app, cached.connectionError)
            cached.trustedDisplayOk == false -> Reasons.withDetail(UNSUPPORTED, cached.gateDetail)
            cached.injectOk != true && cached.injectError != null -> Reasons.withDetail(inputFailureReason(
                BackgroundGateState.InjectFailure.fromWire(cached.injectError)), cached.gateDetail)
            else -> null
        }
    }

    /** This invocation's accepted facts; do not reread a newer probe or connection here. */
    private fun probeReason(receipt: BackgroundGateState.Receipt): String? = when {
        !receipt.trustedDisplayOk -> Reasons.withDetail(UNSUPPORTED, receipt.observation?.encode())
        receipt.injectOk != true -> Reasons.withDetail(
            inputFailureReason(receipt.injectFailure ?: BackgroundGateState.InjectFailure.OTHER), receipt.observation?.encode())
        else -> null
    }

    private fun inputFailureReason(reason: BackgroundGateState.InjectFailure): String = AppStrings.get(app, when (reason) {
        BackgroundGateState.InjectFailure.API_UNAVAILABLE -> R.string.background_input_api_unavailable
        BackgroundGateState.InjectFailure.PERMISSION_DENIED -> R.string.background_input_permission_denied
        BackgroundGateState.InjectFailure.WINDOW_NOT_READY -> R.string.background_input_window_not_ready
        BackgroundGateState.InjectFailure.UNCONFIRMED -> R.string.background_input_unconfirmed
        BackgroundGateState.InjectFailure.CLEANUP_FAILED -> R.string.background_input_cleanup_failed
        BackgroundGateState.InjectFailure.CANCELLED -> R.string.background_input_cancelled
        BackgroundGateState.InjectFailure.OTHER -> R.string.background_injection_denied
    })

    private fun setupFailureResource(code: String?, fallback: Int = R.string.background_not_ready): Int = when (code) {
        "releaseQueryFailed" -> R.string.background_setup_task_query_failed
        "recoveryUnavailable" -> R.string.background_setup_recovery_failed
        "displayUnsupported", "displayTargetChanged", "displayMissing" -> R.string.background_setup_display_failed
        "systemOperationDenied" -> R.string.background_input_permission_denied
        "locked" -> R.string.background_setup_locked
        "scopeHistoryFull" -> R.string.background_setup_history_full
        "bindTimeout" -> R.string.background_setup_bind_timeout
        "unbindTimeout", "bindingBusy" -> R.string.background_setup_unbind_wait
        "unbindFailed", "unbindDispatchFailed" -> R.string.background_setup_unbind_failed
        "bindFailed", "bindDispatchFailed", "noBinder", "probeFailed", "mainThread" -> R.string.background_setup_bind_failed
        "protocolMismatch", "probeRejected", "muxFailed" -> R.string.background_gate_peer_unsupported
        "serviceUnavailable" -> R.string.background_shizuku_stopped
        "permissionDenied" -> R.string.background_shizuku_permission
        "cancelled", "interrupted" -> R.string.background_selection_cancelled
        else -> fallback
    }

    private fun rootReason(): String? {
        val status = root.status()
        if (status.connected) return null
        val resource = when {
            status.starting -> R.string.background_root_starting
            !status.checked -> R.string.background_root_not_selected
            status.reasonCode == "rootTimeout" -> R.string.background_root_timeout
            status.reasonCode == "rootCancelled" -> R.string.background_root_cancelled
            status.reasonCode == "rootIdentityMismatch" -> R.string.background_root_identity
            status.reasonCode == "rootDisconnected" -> R.string.background_root_disconnected
            status.reasonCode == "rootGrantFailed" -> R.string.background_root_grant_failed
            else -> R.string.background_root_failed
        }
        return AppStrings.get(app, resource)
    }

    internal data class Parallelism(val configuredLimit: Int, val effectiveLimit: Int, val reason: String?) {
        fun map(heldSlots: Int): Map<String, Any?> = mapOf("v" to 1,
            "configuredLimit" to configuredLimit, "effectiveLimit" to effectiveLimit,
            "heldSlots" to heldSlots, "reason" to reason)
    }

    /** Main-thread delivery check: only reads the already published preference. */
    internal fun configuredParallelLimit(): Int = parallelLimit

    /** Registry-safe memory snapshot: no controller locks, IPC, permission query or disk. */
    internal fun parallelism(): Parallelism {
        val configured = parallelLimit
        val peer = channel
        val hardLimit = peer?.backgroundLimit ?: 0
        val gateFacts = gate.snapshot
        val unavailable = when {
            mode == "off" -> "off"
            !androidOk() -> "unsupported"
            resourceAdmission() != null -> "resourceRecovery"
            selfCheckBorrow != null || gateCall != null || gate.needsRetest || selectingResource ||
                interruptRequested || selectionChange != null || restoring?.isDone == false -> "busy"
            gateFacts.connectionError != null -> "connectionRequired"
            gateFacts.trustedDisplayOk == false || gateFacts.injectOk == false ||
                gateFacts.injectOk != true && gateFacts.injectError != null -> "unsupported"
            peer == null -> "connectionRequired"
            hardLimit == 0 -> "peerUnsupported"
            else -> null
        }
        return if (unavailable != null) Parallelism(configured, 0, unavailable)
        else Parallelism(configured, minOf(configured, hardLimit),
            if (hardLimit < configured) "transportSerial" else null)
    }

    // ---- actions -----------------------------------------------------------

    /** Save before publication; existing logical leases and original resources remain owned. */
    internal fun setBackgroundParallelLimit(value: Any?): Map<String, Any?> {
        if (value !is Int || value !in 1..3)
            return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_parallel_limit_invalid))
        val saved = synchronized(preferenceGuard) {
            if (!parallelPrefs.edit().putInt("limit", value).commit()) false
            else { parallelLimit = value; true }
        }
        return if (saved) mapOf("ok" to true)
        else mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_parallel_limit_save_failed))
    }

    /** Preference only. Existing drivers keep their captured viewport until released. */
    fun setBackgroundViewport(value: Any?): Map<String, Any?> {
        val selected = BackgroundPolicy.Viewport.parse(value)
            ?: return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_viewport_invalid))
        val saved = synchronized(preferenceGuard) {
            if (!viewportPrefs.edit().putString("preset", selected.preset).commit()) false
            else { viewport = selected; true }
        }
        if (saved) notifyChanged()
        return if (saved) mapOf("ok" to true)
            else mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_viewport_save_failed))
    }

    fun setBackgroundMode(newMode: String, mayStart: () -> Boolean = { true }): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        try {
            val provider = shizuku.status().provider
            val selected = PrivilegedPathPolicy.canonicalMode(newMode, provider)
                ?: return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_unknown_mode))
            if (selected == "sui" && provider != ShizukuStatus.SUI) {
                return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_sui_not_provider))
            }
            if (selected != "off" && !androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
            val changing = selected != mode || selected == "off"
            synchronized(this) {
                synchronized(keepGuard) {
                    if (selectingResource || interruptRequested || gateCall != null || selfCheckBorrow != null ||
                        transportUsers != 1 || restoring != null || selectionChange != null || !changing && taskResource.occupied) return transportBusy()
                    // Same-mode retests reserve the resource too, before any connection work.
                    selectingResource = true
                    // Connection/reset callbacks may arrive before the resource slot exists.
                    // This explicit check cannot inherit old/unknown capability readiness.
                    if (selected != "off") gate.requireRetest()
                    if (changing) taskResource.seal().forEach { it.driver.seal() }
                }
            }
            try {
                // Do not change the selected transport while its original resource remains unconfirmed.
                if (changing && !endTask()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.phone_background_cleanup_before_switch))
                val (selection, transition, previewChanged) = synchronized(this) {
                    synchronized(keepGuard) {
                        if (!mayStart() || selectionChange != null) return keepFailure("selectionChanged")
                        val leaving = if (mode == "sui") "shizuku" else mode
                        val owner = if (changing) Any().also { selectionChange = it } else null
                        keep.select(selected)
                        rootSelected = selected == "root"
                        val changed = changing && replaceChannel(null)
                        Triple(keep.selectionTicket(), owner?.let { it to leaving }, changed)
                    }
                }
                if (previewChanged) onPreviewChanged()
                if (transition != null) {
                    try {
                        // Retire the old family before admitting new borrowers; no long IPC under keepGuard.
                        disconnectTransports { selected == "off" || it == transition.second }
                        gate.reset()
                    } finally {
                        val finished = synchronized(keepGuard) {
                            if (selectionChange !== transition.first) false
                            else { selectionChange = null; true }
                        }
                        // configure() may have changed keep generation while cleanup ran. The transition
                        // owns its own completion, and a newly saved keep must get another restore chance.
                        if (finished) restoreKeptChannel()
                    }
                }
                val allowed = { mayStart() && !interruptRequested && selectionChange == null && keep.selectionCurrent(selection) }
                val cleared = synchronized(preferenceGuard) {
                    keep.keptMode != "off" || keepPrefs.edit().putString("keptMode", "off").commit()
                }
                updateKeepListeners()
                if (!cleared) { notifyChanged(); return keepFailure("persistenceFailed") }
                when (selected) {
                    "off" -> { notifyChanged(); return mapOf("ok" to true) }
                    "shizuku", "sui" -> shizuku.ensureListeners()
                    // 不打扰模式's only su; tasks just connect() to what it leaves.
                    "root" -> root.start(allowed)?.let { connected ->
                        val changed = synchronized(this) {
                            synchronized(keepGuard) { allowed() && replaceChannel(connected) }
                        }
                        if (changed) onPreviewChanged()
                    }
                }
                notifyChanged()
                if (!allowed()) return keepFailure("selectionChanged")
                // Probe eagerly so the UI can hide an unsupported switch rather than fail later.
                val probe = runGateProbe(selection, allowed)
                return mapOf("ok" to (probe == null), "reason" to probe)
            } finally {
                synchronized(this) { selectingResource = false }
                finishInterrupt()
                if (keep.enabled) restoreKeptChannel()
            }
        } finally { endTransportUse() }
    }

    fun requestShizukuPermission(provider: String? = null): Boolean =
        (provider == null || provider == shizuku.status().provider) && shizuku.requestPermission()

    /** Root for the explicit WSS grant; it never changes the background mode. */
    fun prepareRoot(mayStart: () -> Boolean): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        var ownsSelection = false
        try {
            val original = synchronized(this) {
                synchronized(keepGuard) {
                    if (mode != "root") null
                    else taskResource.boundPeer ?: run {
                        if (transportUsers != 1 || restoring?.isDone == false || selectionChange != null)
                            return transportBusy()
                        selectingResource = true
                        ownsSelection = true
                        null
                    }
                }
            }
            rootSelected = true
            // A different family is an authorized temporary WSS path. Its transport reservation
            // prevents mode switching until finally; the current background peer remains untouched.
            val connected = if (original != null) original.takeIf { mayStart() && it.alive() }
                else root.start { mayStart() && !interruptRequested }
            return if (connected != null) mapOf("ok" to true)
                else mapOf("ok" to false, "reason" to rootReason())
        } finally {
            if (ownsSelection) synchronized(this) { selectingResource = false }
            endTransportUse()
            notifyChanged()
        }
    }

    fun rootGrantSelected(): Boolean = rootSelected

    /** Detach invalidates only the caller's unpublished UI attempt, not borrowed healthy channels. */
    fun cancelUnwantedPending() {
        // Seal the original lane before revoking its presentation probe. Published peers stay pinned.
        synchronized(keepGuard) { gateCall?.takeIf { !gate.current(it.probe) }?.io?.seal() }
        gate.cancelUnwantedPending()
        root.cancelUnwantedPending()
        shizuku.cancelUnwantedPending()
        adb.cancelUnwantedPending()
    }

    fun cancelRootSelection() {
        rootSelected = false
        // Revoke unpublished authorization now; a borrowed resource pin closes only after cleanup.
        root.cancelUnwantedPending()
    }

    private fun secureSettingsGranted(): Boolean =
        app.checkSelfPermission(SecureSettingsGrant.PERMISSION) == PackageManager.PERMISSION_GRANTED

    /** The RPC result isn't the answer: the permission itself is. An existing root connection is required. */
    fun grantRootSecureSettings(): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        try {
            if (secureSettingsGranted()) return mapOf("ok" to true)
            val ran = root.grantSecureSettings()
            if (secureSettingsGranted()) return mapOf("ok" to true)
            return mapOf("ok" to false, "reason" to ((if (ran) null else rootReason()) ?: AppStrings.get(app, R.string.background_root_grant_failed)))
        } finally { endTransportUse() }
    }

    fun adbStartPairing(): Map<String, Any?> {
        if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
        return pairing.submit<Map<String, Any?>> {
            AdbPairingNotification.show(app)
            adb.startPairing()
        }.get()
    }

    fun adbPair(code: String, port: Int?): Map<String, Any?> = pairing.submit<Map<String, Any?>> { adb.pair(code, port) }.get()

    /** The code typed into the notification: paired after anything queued, its result shown from the queue. */
    fun adbPairFromNotification(code: String) {
        pairing.execute { AdbPairingNotification.showResult(app, adb.pair(code, null)) }
    }

    fun adbConnect(port: Int? = null, mayStart: () -> Boolean = { true }): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        var ownsSelection = false
        try {
            if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
            if (port != null && port !in 1..65535)
                return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_adb_invalid_port))
            val original = synchronized(this) {
                synchronized(keepGuard) {
                    if (mode != "adb") null
                    else taskResource.boundPeer ?: run {
                        if (transportUsers != 1 || restoring?.isDone == false || selectionChange != null)
                            return transportBusy()
                        selectingResource = true
                        ownsSelection = true
                        null
                    }
                }
            }
            val connected = if (original != null) mayStart() && original.alive()
                else adb.connect(port, mayStart = { mayStart() && !interruptRequested }) != null
            return mapOf("ok" to connected, "reason" to if (connected) null else adb.reason())
        } finally {
            if (ownsSelection) synchronized(this) { selectingResource = false }
            endTransportUse()
            notifyChanged()
        }
    }

    // ---- 自动恢复无障碍 (WRITE_SECURE_SETTINGS through the engine) -------------

    /** The one-tap way to the permission right now ([SecureSettingsGrant.path]). */
    fun grantPath(granted: Boolean): String =
        if (granted) SecureSettingsGrant.GRANTED else SecureSettingsGrant.path(false, shizuku.status(), adb.status())

    /**
     * Has the engine grant the permission over [via] (`shizuku` / `adb`): 不打扰模式's channel when it
     * uses the same starter, else one opened for this and closed after. Blocks (an adb connect can
     * take seconds). Retains this attempt before closing any temporary channel.
     */
    fun grantSecureSettings(via: String, mayStart: () -> Boolean): SecureSettingsGrant.Attempt {
        if (!beginTransportUse()) return SecureSettingsGrant.Attempt.UNAVAILABLE
        try {
            if (!mayStart()) return SecureSettingsGrant.Attempt.CANCELLED
            val sharedApi = via == SecureSettingsGrant.SHIZUKU || via == SecureSettingsGrant.SUI
            val shared = PrivilegedPathPolicy.sharesGrantChannel(mode, via)
            val ch = when {
                shared -> activeChannel(mayStart, transportReserved = true)
                sharedApi -> shizuku.connect(mayStart = mayStart)
                else -> adb.connect(mayStart = mayStart)
            }
            try {
                // A connect may return null because the original UI lease was cancelled.
                if (!mayStart()) return SecureSettingsGrant.Attempt.CANCELLED
                if (ch == null) return SecureSettingsGrant.Attempt.UNAVAILABLE
                val request = Bundle().apply {
                    putString(Proto.OP, Proto.OP_GRANT_SECURE_SETTINGS)
                    putInt(Proto.USER, Process.myUid() / PER_USER_RANGE)
                }
                return runCatching {
                    val response = ch.execute(request)
                    SecureSettingsGrant.attempt(response.getBoolean(Proto.OK), response.getString(Proto.ERROR))
                }.getOrDefault(SecureSettingsGrant.Attempt.UNAVAILABLE)
            } finally {
                // Shared task channels remain owned by their task; only retire this temporary link.
                if (!shared) if (sharedApi) shizuku.disconnectIfCurrent(ch) else adb.disconnectIfCurrent(ch)
            }
        } finally { endTransportUse() }
    }

    fun requestShizukuPermission(then: () -> Unit): Boolean = shizuku.requestPermission(then)

    /** Read-only diagnostics: only the already selected live link; never starts a transport or gate. */
    fun collectSystemIme(mayStart: () -> Boolean): Map<String, Any?> {
        val evidence = io.github.ccch1mneyyy.dsh_app.diagnostics.SystemImeEvidence
        if (!mayStart()) return evidence.result("cancelled")
        if (PhoneControl.peek()?.tasks?.snapshot()?.active == true || taskResource.occupied)
            return evidence.result("busy")
        val selected = synchronized(keepGuard) {
            if (selectionChange != null || mode == "off") return evidence.result("unavailable")
            keep.selectionTicket() to channel
        }
        val ch = selected.second ?: return evidence.result("unavailable")
        if (!ch.alive()) return evidence.result("unavailable")
        val allowed = { mayStart() && selectionChange == null && keep.selectionCurrent(selected.first) && channel === ch }
        if (!allowed()) return evidence.result("cancelled")
        return try {
            val response = ch.execute(Bundle().apply {
                putString(Proto.OP, Proto.OP_COLLECT_SYSTEM_IME)
                putInt(Proto.IME_PID, Process.myPid())
                putLong(Proto.IME_REQUESTED_AT, System.currentTimeMillis())
            })
            if (!allowed()) return evidence.result("cancelled")
            val code = evidence.coreCode(response.getBoolean(Proto.OK), response.getString(Proto.ERROR))
            if (code != "ok" && code != "noEvents") return evidence.result(code)
            val at = response.getLong("capturedAt")
            if (at <= 0 || kotlin.math.abs(System.currentTimeMillis() - at) > 10_000)
                return evidence.result("failed")
            val times = response.getLongArray("imeTimes") ?: return evidence.result("failed")
            val events = response.getStringArray("imeEvents") ?: return evidence.result("failed")
            val users = response.getIntArray("imeFromUser") ?: return evidence.result("failed")
            val reasons = response.getStringArray("imeReasons") ?: return evidence.result("failed")
            val origins = response.getStringArray("imeOrigins") ?: return evidence.result("failed")
            if (times.size > evidence.MAX_EVENTS || listOf(events.size, users.size, reasons.size, origins.size).any { it != times.size })
                return evidence.result("failed")
            val safe = times.indices.map { i ->
                if (users[i] !in -1..1) return evidence.result("failed")
                io.github.ccch1mneyyy.dsh_app.diagnostics.SystemImeEvent(times[i], events[i],
                    when (users[i]) { 1 -> true; 0 -> false; else -> null }, reasons[i], origins[i])
            }
            if (safe.any { !evidence.valid(it, at) } || (code == "noEvents") != safe.isEmpty())
                return evidence.result("failed")
            evidence.result(code, at, safe)
        } catch (_: Exception) { evidence.result(if (mayStart()) "unavailable" else "cancelled") }
    }

    // ---- task lifecycle (called by the bridge/core) ------------------------

    /** Sessions calls this outside registry/Tasks/worker locks, before acquiring BG leases. */
    internal fun prepareForTask(owner: PhoneTasks.Owner, currentOwner: () -> Boolean): String? {
        if (!currentOwner()) return AppStrings.get(app, R.string.background_selection_cancelled)
        resourceAdmission()?.let { return it }
        if (mode == "off" || !androidOk()) return readiness() ?: AppStrings.get(app, R.string.background_not_ready)
        synchronized(this) {
            // Reuse does not create a slot or replace a peer. Other WSS users must not revoke it.
            if (taskResource.find(owner) != null) return null
        }
        if (keep.enabled && (channel?.backgroundLimit ?: 0) == 0) {
            try { restoreKeptChannel()?.get() } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return AppStrings.get(app, R.string.background_selection_cancelled)
            } catch (_: Exception) { return AppStrings.get(app, R.string.background_not_ready) }
        }
        if (activeChannel(currentOwner) == null || parallelism().effectiveLimit == 0)
            return readiness() ?: AppStrings.get(app, R.string.background_not_ready)
        return null
    }

    /** Read-only original record lookup. No bootstrap, slot acquisition, IPC or target change. */
    fun existingReplayDriver(owner: PhoneTasks.Owner, app: PhoneAppIdentity,
                             currentOwner: () -> Boolean): BackgroundDisplay? {
        fun current() = owner.active && currentOwner() && !Thread.currentThread().isInterrupted
        if (!current() || mode == "off" || !androidOk() || resourceAdmission() != null) return null
        val record = synchronized(this) {
            synchronized(keepGuard) {
                if (resourceMaintenance != null || retiredResourcePeer != null || selfCheckBorrow != null ||
                    gateCall != null || gate.needsRetest || interruptRequested || selectingResource ||
                    restoring?.isDone == false || selectionChange != null) return null
                taskResource.find(owner)?.takeIf { channel === it.peer } ?: return null
            }
        }
        // mayUse consults the original Tasks owner; never call it under controller/keep locks.
        // The driver inspects its original allocation/peer/IO state without platform calls.
        if (!record.driver.existingReplayTarget(app) || !current() || resourceAdmission() != null) return null
        return synchronized(this) {
            synchronized(keepGuard) {
                if (mode == "off" || channel !== record.peer || !taskResource.current(record) ||
                    resourceMaintenance != null || retiredResourcePeer != null || selfCheckBorrow != null ||
                    gateCall != null || gate.needsRetest || interruptRequested || selectingResource ||
                    restoring?.isDone == false || selectionChange != null) null else record.driver
            }
        }
    }

    /** The lease already exists. The actual channel returned here becomes this driver's peer. */
    fun driverForTask(owner: PhoneTasks.Owner, currentOwner: () -> Boolean,
                      admitOwner: ((() -> Unit) -> Boolean)): BackgroundDisplay? {
        fun current() = currentOwner() && !Thread.currentThread().isInterrupted
        if (mode == "off" || !androidOk() || resourceAdmission() != null) return null
        val selection = synchronized(this) {
            synchronized(keepGuard) {
                if (resourceMaintenance != null || retiredResourcePeer != null || selfCheckBorrow != null ||
                    gateCall != null || gate.needsRetest || interruptRequested || !current()) return null
                taskResource.find(owner)?.let { return it.driver }
                if (selectingResource || restoring?.isDone == false || selectionChange != null) return null
                keep.selectionTicket()
            }
        }
        fun allowed() = current() && keep.selectionCurrent(selection)
        // Bootstrap before the lease was only preparation. Capture this invocation's actual peer;
        // no controller monitor is held while checking or establishing the authorized channel.
        val peer = activeChannel(::allowed) ?: return null
        val ocr = MlKitLocalOcr.get(app) // First preference read stays outside resource monitors.
        val acquired = synchronized(this) {
            synchronized(keepGuard) {
                if (!allowed() || channel !== peer || resourceMaintenance != null || retiredResourcePeer != null ||
                    selfCheckBorrow != null || gateCall != null || gate.needsRetest || interruptRequested ||
                    selectingResource || restoring?.isDone == false || selectionChange != null) return null
                lateinit var record: BackgroundTaskSlot.TaskResource<BackgroundDisplay, PrivilegedChannel>
                record = taskResource.acquire(owner, peer, peer.backgroundLimit, ::allowed) {
                    BackgroundDisplay(
                        channelProvider = { peer },
                        journal = resourceJournal,
                        mayUse = { currentOwner() && !interruptRequested },
                        admitUse = { action -> admitOwner { check(!interruptRequested); action() } },
                        viewport = viewport,
                        localOcr = ocr,
                        localOcrAllowed = { target -> localOcrAllowed(target) },
                        onResourceReady = { publishPreviewTarget(record, it) },
                    )
                } ?: return null
                record
            }
        }
        notifyChanged()
        return acquired.driver
    }

    /** Immediately seals every selected original; null explicitly means all. */
    fun sealTask(expectedTaskId: Long? = null) {
        var changed = false
        synchronized(this) {
            for (record in taskResource.seal(expectedTaskId)) {
                record.driver.seal()
                changed = withdrawPreviewTarget(record.driver) || changed
            }
        }
        if (changed) onPreviewChanged()
    }

    /** Seal the whole batch before releasing any member; commit each strict result by identity. */
    fun endTask(expectedTaskId: Long? = null): Boolean {
        var previewChanged = false
        val captured = synchronized(this) {
            taskResource.seal(expectedTaskId).onEach {
                it.driver.seal()
                previewChanged = withdrawPreviewTarget(it.driver) || previewChanged
            }
        }
        if (previewChanged) onPreviewChanged()
        var released = true
        for (record in captured) {
            if (!record.driver.release() || !taskResource.complete(record)) released = false
        }
        if (captured.isNotEmpty()) notifyChanged()
        finishInterrupt()
        return released
    }

    /** Keep the gate closed until the logical stop batch has committed outside controller locks. */
    fun requestInterrupt(stopTasks: () -> Unit) {
        var changed = false
        synchronized(this) {
            interruptStopping = true
            gate.changeIntent { interruptRequested = true }
            synchronized(keepGuard) { gateCall?.io?.seal() }
            for (record in taskResource.seal()) {
                record.driver.seal()
                changed = withdrawPreviewTarget(record.driver) || changed
            }
        }
        if (changed) onPreviewChanged()
        // The screen-off caller has already stopped the self-check Run. Do not move that
        // cancellation past this boundary: its beforeSend commits under the original Run lock.
        stopTasks()
        synchronized(this) { interruptStopping = false }
        // The caller schedules finishInterrupt on its existing cleanup executor, never on main.
    }

    fun finishInterrupt() {
        synchronized(this) {
            if (!interruptRequested || interruptStopping || interruptFinishing || taskResource.occupied || selectingResource) return
            synchronized(keepGuard) {
                if (resourceMaintenance != null || retiredResourcePeer != null || selfCheckBorrow != null ||
                    gateCall != null || transportUsers != 0 || restoring != null || selectionChange != null) return
                interruptFinishing = true
            }
        }
        var disconnected = false
        try {
            disconnectAll(PrivilegedPathPolicy::closesOnInterrupt)
            disconnected = true
        } finally {
            synchronized(this) {
                // Merge overlapping screen-off intents only after the latest logical stop
                // has returned. No new resource can publish while requested stays true.
                // Clearing finishing in this SAME commit prevents a lost cleanup wake-up.
                if (disconnected && !interruptStopping) interruptRequested = false
                interruptFinishing = false
            }
            notifyChanged()
        }
    }

    // ---- channel plumbing --------------------------------------------------

    private fun activeChannel(mayStart: () -> Boolean = { true }, explicit: Boolean = false,
                              transportReserved: Boolean = false, recoveryOnly: Boolean = false): PrivilegedChannel? {
        if (!transportReserved && !beginTransportUse()) return null
        var ownsSelection = false
        var previewChanged = false
        try {
            if (!mayStart() || !recoveryOnly && interruptRequested) return null
            val (selection, cached, bound) = synchronized(this) {
                synchronized(keepGuard) {
                    if (selectionChange != null) return null
                    Triple(keep.selectionTicket(), channel, taskResource.boundPeer)
                }
            }
            // Starter guards may call this; the predicate must not acquire controller locks.
            val allowed = { mayStart() && (recoveryOnly || !interruptRequested) && selectionChange == null && keep.selectionCurrent(selection) }
            val selected = selection.mode
            if ((selected == "shizuku" || selected == "sui") && shizuku.status().provider != selected) return null
            val observed = gate.snapshot
            if (!recoveryOnly && bound != null && cached !== bound) return null
            if (cached?.alive() == true) return synchronized(this) {
                synchronized(keepGuard) {
                    if (!allowed() || channel !== cached) null
                    else { gate.connected(observed, cached); cached }
                }
            }
            // Ordinary calls never replace a retained peer. Only the existing explicit recovery
            // reservation may connect a verifier; it does not move or release any original slot.
            if ((!recoveryOnly && bound != null) || !allowed() || keep.enabled && !explicit) return null
            if (!recoveryOnly) synchronized(this) {
                synchronized(keepGuard) {
                    if (!allowed() || taskResource.occupied || selfCheckBorrow != null || gateCall != null ||
                        transportUsers != 1 || restoring?.isDone == false || selectionChange != null) return null
                    if (!selectingResource) {
                        selectingResource = true
                        ownsSelection = true
                    }
                    // Otherwise the explicit settings caller owns the same existing reservation.
                }
            }
            if (ownsSelection) notifyChanged()
            val connected = when (selected) {
                "shizuku", "sui" -> shizuku.connect(mayStart = allowed)
                "root" -> root.connect() ?: if (recoveryOnly) root.start(allowed) else null
                "adb" -> adb.connect(mayStart = allowed)
                else -> null
            } ?: return null
            return synchronized(this) {
                synchronized(keepGuard) {
                    if (!allowed()) null else {
                        previewChanged = replaceChannel(connected)
                        gate.connected(observed, connected)
                        connected
                    }
                }
            }
        } finally {
            if (ownsSelection) synchronized(this) { selectingResource = false }
            if (previewChanged) onPreviewChanged()
            if (!transportReserved) endTransportUse()
            if (ownsSelection) notifyChanged()
        }
    }

    private fun disconnectAll(closes: (String) -> Boolean = { true }) {
        val changed = synchronized(this) { synchronized(keepGuard) { replaceChannel(null) } }
        if (changed) onPreviewChanged()
        disconnectTransports(closes)
    }

    private fun disconnectTransports(closes: (String) -> Boolean) {
        if (closes("shizuku")) shizuku.disconnect()
        if (closes("adb")) adb.disconnect()
        if (closes("root")) root.disconnect()
    }

    /** Settings owns one outer transport use. The original resource survives a cancelled UI. */
    private fun runGateProbe(selection: PrivilegedKeepState.Ticket, mayStart: () -> Boolean): String? {
        fun rejectedBeforeAllocation(reason: Int): String {
            val probe = gate.begin(mayStart) ?: return AppStrings.get(app, R.string.background_selection_cancelled)
            gate.failed(probe, reason)
            gate.concludedWithoutAllocation(probe)
            notifyChanged()
            return AppStrings.get(app, reason)
        }
        val starterReason = when (mode) {
            "shizuku", "sui" -> shizuku.reason()
            "root" -> rootReason()
            "adb" -> adb.reason()
            else -> AppStrings.get(app, R.string.background_off)
        }
        if (starterReason != null) {
            rejectedBeforeAllocation(R.string.background_not_ready)
            return starterReason
        }
        var peer = activeChannel(mayStart, explicit = true, transportReserved = true)
            ?: return rejectedBeforeAllocation(setupFailureResource(
                if (selection.mode == "shizuku" || selection.mode == "sui") shizuku.connectReasonCode else null))
        if (recoverResourceRecords(peer, selection, mayStart, settingsUse = true) != null)
            return AppStrings.get(app, R.string.background_resource_recovery_pending)
        if (!peer.alive()) {
            // runGateProbe is reached only from the user's existing explicit setBackgroundMode.
            if (selection.mode == "root" && mayStart()) root.start(mayStart)?.let { fresh ->
                val changed = synchronized(this) {
                    synchronized(keepGuard) { mayStart() && replaceChannel(fresh) }
                }
                if (changed) onPreviewChanged()
            }
            peer = activeChannel(mayStart, explicit = true, transportReserved = true)
                ?: return AppStrings.get(app, R.string.background_not_ready)
        }
        if (resourceAdmission() != null) return AppStrings.get(app, R.string.background_resource_recovery_pending)
        val probe = gate.begin(mayStart) ?: return AppStrings.get(app, R.string.background_selection_cancelled)
        fun failed(reason: Int, peer: PrivilegedChannel? = null): String {
            if (!gate.failed(probe, reason, peer)) return AppStrings.get(app, R.string.background_selection_cancelled)
            notifyChanged()
            return AppStrings.get(app, reason)
        }

        val call = synchronized(this) {
            synchronized(keepGuard) {
                // This settings body owns the only transport reservation, including its connection work.
                if (interruptRequested || channel !== peer || !keep.selectionCurrent(selection) || !gate.current(probe))
                    return AppStrings.get(app, R.string.background_selection_cancelled)
                if (taskResource.occupied || selfCheckBorrow != null || gateCall != null || transportUsers != 1 ||
                    restoring != null || selectionChange != null) return AppStrings.get(app, R.string.background_input_probe_busy)
                BackgroundGateCall(peer, probe, resourceJournal).also { gateCall = it }
            }
        }
        notifyChanged()
        var accepted: BackgroundGateState.Update.Accepted? = null
        var reason: String? = null
        var released = false
        var published = false
        try {
            call.io.call {
                if (!gate.current(probe)) { reason = AppStrings.get(app, R.string.background_selection_cancelled); return@call }
                val cap = peer.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) })
                if ((cap.get(Proto.OK) as? Boolean) != true ||
                    !OwnerScopeProtocol.supported(cap) || (cap.get(Proto.SELF_CHECK_PROBE_VERSION) as? Int) != 1 ||
                    backgroundRequestLimit(cap::get, cap::containsKey, false) == 0) {
                    reason = failed(setupFailureResource(cap.getString(Proto.ERROR), R.string.background_gate_peer_unsupported), peer)
                    return@call
                }
                val birth = BackgroundRecoveryProtocol.birth(cap::get, cap::containsKey)
                if (birth == null) {
                    reason = failed(R.string.background_setup_recovery_failed, peer)
                    return@call
                }
                if (!call.resource.begin(birth)) { reason = AppStrings.get(app, R.string.background_resource_recovery_pending); return@call }
                val allocation = OwnerScopeProtocol.first(call.io, peer,
                    BackgroundRecoveryProtocol.allocate(call.io.owner, "probe", null)) { commit -> gate.admit(probe, commit) }
                val actualId = BackgroundRecoveryProtocol.allocationId(allocation::get)
                if (actualId == null) {
                    reason = failed(setupFailureResource(allocation.getString(Proto.ERROR), R.string.background_setup_display_failed), peer)
                    return@call
                }
                if (!call.resource.allocated(actualId) { gate.current(probe) && !call.io.previewClosed() }) {
                    reason = AppStrings.get(app, R.string.background_resource_recovery_pending)
                    return@call
                }
                val request = Bundle().apply {
                    putString(Proto.OP, Proto.OP_SELF_CHECK_PROBE)
                    putString(Proto.OWNER, call.io.owner)
                    putInt(Proto.SELF_CHECK_PROBE_VERSION, 1)
                    putInt(Proto.RELEASE_RECEIPT, 1)
                }
                if (!gate.current(probe)) { reason = AppStrings.get(app, R.string.background_selection_cancelled); return@call }
                val reply = OwnerScopeProtocol.execute(peer, call.io.owner, request) {
                    check(gate.admit(probe) { call.io.checkDispatch() })
                }
                when (val result = gate.updateStrict(probe, call.io.owner, reply.get(Proto.OWNER),
                    reply.get(Proto.SELF_CHECK_PROBE_VERSION), reply.get(Proto.OK),
                    reply.get(Proto.SELF_CHECK_DISPLAY_READY), reply.get(Proto.INJECT_OK),
                    reply.get(Proto.ERROR), reply.get(Proto.INJECT_ERROR), reply.get(Proto.ERROR_DETAIL))) {
                    is BackgroundGateState.Update.Accepted -> { accepted = result; reason = probeReason(result.receipt) }
                    BackgroundGateState.Update.Cancelled -> reason = AppStrings.get(app, R.string.background_selection_cancelled)
                    BackgroundGateState.Update.Busy -> reason = AppStrings.get(app, R.string.background_input_probe_busy)
                    BackgroundGateState.Update.Invalid -> reason = failed(R.string.background_no_response, peer)
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            reason = AppStrings.get(app, R.string.background_selection_cancelled)
        } catch (_: Exception) {
            reason = failed(R.string.background_no_response, peer)
        } finally {
            // Initial cleanup claims before any UI retry; the original I/O has really drained.
            val physical = call.finishProbeAndCleanup(::releaseGate)
            released = finishGateCall(call, physical) {
                val receipt = accepted?.receipt
                if (receipt != null && !Thread.currentThread().isInterrupted) {
                    // Cleanup completion and capability success are separate facts. Failed
                    // checks keep their real error, not a permanent "check again" barrier.
                    published = gate.completedWithCleanup(probe)
                } else if (gate.snapshot.connectionError != null && !Thread.currentThread().isInterrupted) {
                    gate.completedWithCleanup(probe)
                }
            }
        }
        if (!released) return AppStrings.get(app, R.string.background_gate_cleanup_pending)
        if (accepted != null && !published) return AppStrings.get(app, R.string.background_selection_cancelled)
        return if (accepted != null) reason else reason ?: AppStrings.get(app, R.string.background_no_response)
    }

    /** Retry retains the exact handle. A dead pin only permits strict original-scope recovery. */
    fun retryGateCleanup(handle: String): Map<String, Any?> {
        val call = synchronized(keepGuard) {
            gateCall?.takeIf { it.handle == handle }
        } ?: return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_gate_cleanup_stale))
        if (!call.peer.alive() && !call.resource.physicalComplete) {
            val reason = recoverOriginalResource(null, call)
            return mapOf("ok" to (reason == null), "reason" to reason)
        }
        val released = finishGateCall(call, call.retryCleanup(::releaseGate))
        return mapOf("ok" to released, "reason" to if (released) null else AppStrings.get(app, R.string.background_gate_cleanup_pending))
    }

    private fun releaseGate(peer: PrivilegedChannel, owner: String): Boolean {
        notifyChanged() // phase is now cleaning; no controller or I/O state lock is held.
        val reply = OwnerScopeProtocol.execute(peer, owner, Bundle().apply {
            putString(Proto.OP, Proto.OP_RELEASE)
            putString(Proto.OWNER, owner)
            putInt(Proto.RELEASE_RECEIPT, 1)
        })
        return BackgroundReleaseReceipt.accepts(owner, reply.get(Proto.RELEASE_RECEIPT), reply.get(Proto.OWNER),
            reply.get(Proto.OK), reply.get("released"), reply.get(Proto.TASK_SCOPE_EMPTY), reply.get("neverCreated"))
    }

    /** Exact slot publication is short; no RPC or UI callback runs under keepGuard. */
    private fun finishGateCall(call: BackgroundGateCall<PrivilegedChannel>, released: Boolean, afterRelease: () -> Unit = {}): Boolean {
        val cleared = synchronized(keepGuard) {
            if (!released || gateCall !== call) false
            else {
                afterRelease()
                gateCall = null
                true
            }
        }
        notifyChanged()
        if (cleared) finishInterrupt()
        return cleared
    }

    // ---- explicit channel keep consent and event-driven recovery ------------

    /** Main-thread intent boundary. The returned ticket is persisted on the short control queue. */
    internal fun changeKeep(selected: String, enabled: Boolean): Pair<PrivilegedKeepState.Ticket?, String?> {
        val failure = when {
            enabled && !androidOk() -> "unsupportedAndroid"
            enabled && !PhoneControl.switchedOn(app) -> "phoneDisabled"
            else -> null
        }
        if (failure != null) return null to failure
        // Checked under the guard keep.select takes: an off or a switch queued just before this tap
        // either lands first (selectionChanged) or resets this consent, never leaves the old mode kept.
        val ticket = synchronized(keepGuard) {
            if (selected != mode || selected !in PrivilegedKeepState.MODES) null
            else gate.changeIntent { keep.configure(if (enabled) selected else "off") }
        } ?: return null to "selectionChanged"
        cancelUnwantedPending()
        if (!enabled) { updateKeepListeners(); PrivilegedKeepJob.cancel(app) }
        notifyChanged()
        return ticket to null
    }

    /** A previously disabled phone must not revive an old persisted keep on the next process start. */
    internal fun preparePhoneEnable(): Boolean = PhoneControl.switchedOn(app) || saveKeep(clearKeep())["ok"] == true

    internal fun clearKeepForMode(requested: String): PrivilegedKeepState.Ticket? {
        cancelUnwantedPending()
        val selected = PrivilegedPathPolicy.canonicalMode(requested, shizuku.status().provider)
        return if (selected != mode || selected == "off") clearKeep() else null
    }

    /** Called immediately on mode/off intents, before any queued or blocked transport operation. */
    internal fun clearKeep(): PrivilegedKeepState.Ticket {
        val ticket = synchronized(keepGuard) { gate.changeIntent { keep.configure("off") } }
        cancelUnwantedPending()
        updateKeepListeners()
        PrivilegedKeepJob.cancel(app)
        notifyChanged()
        return ticket
    }

    internal fun saveKeep(ticket: PrivilegedKeepState.Ticket): Map<String, Any?> {
        val ok: Boolean
        val accepted: Boolean
        synchronized(preferenceGuard) {
            if (!keep.saving(ticket)) return keepFailure("selectionChanged")
            ok = keepPrefs.edit().putString("keptMode", ticket.mode).commit()
            accepted = synchronized(keepGuard) { keep.saved(ticket, ok) }
        }
        if (!accepted) return keepFailure(if (ok) "selectionChanged" else "persistenceFailed")
        updateKeepListeners()
        if (keep.enabled) restoreKeptChannel()
        notifyChanged()
        return mapOf("ok" to true)
    }

    internal fun keepFailure(code: String): Map<String, Any?> = mapOf("ok" to false, "reasonCode" to code,
        "reason" to AppStrings.get(app, when (code) {
            "phoneDisabled" -> R.string.background_keep_phone_disabled
            "unsupportedAndroid" -> R.string.background_requires_android
            "persistenceFailed" -> R.string.background_keep_save_failed
            else -> R.string.background_selection_cancelled
        }))

    /** Foreground/start/BOOT hook; existing explicit keep consent only. */
    fun restoreKeptChannel(): Future<PrivilegedChannel?>? {
        if (interruptRequested || !PhoneControl.switchedOn(app) || !androidOk() || !keep.enabled) return null
        updateKeepListeners()
        synchronized(this) {
            synchronized(keepGuard) {
                if (resourceMaintenance != null || retiredResourcePeer != null || interruptRequested ||
                    selectingResource || gateCall != null || selectionChange != null || selfCheckBorrow != null ||
                    transportUsers != 0) return null
                restoring?.let {
                    if (restoringTicket?.let(keep::current) != true) restoreAgain = true
                    return it
                }
                val ticket = keep.begin(SystemClock.elapsedRealtime()) ?: return null
                // The same monitor protects both this reservation and future slot publication.
                // A queued restore retains this exact peer even if its last record later clears.
                val original = taskResource.boundPeer
                val task = FutureTask { restore(ticket, original) }
                restoring = task
                restoringTicket = ticket
                recovery.execute {
                    try { task.run() } finally {
                        val again = synchronized(keepGuard) {
                            restoring = null; restoringTicket = null
                            restoreAgain.also { restoreAgain = false }
                        }
                        finishInterrupt()
                        if (again) {
                            synchronized(keepGuard) { keep.available(ticket) }
                            restoreKeptChannel()
                        }
                    }
                }
                return task
            }
        }
    }

    private fun restore(ticket: PrivilegedKeepState.Ticket, original: PrivilegedChannel?): PrivilegedChannel? {
        val observed = gate.snapshot
        var failure: String? = "connectFailed"
        var waiting = false
        var value: PrivilegedChannel? = null
        var previewChanged = false
        fun allowed() = !interruptRequested && !selectingResource && gateCall == null && keep.current(ticket)
        try {
            if (!allowed()) return null
            value = if (original != null) {
                // No fallback start/connect, even when this original is now dead or unknown.
                original.takeIf { it.alive() }
            } else when (ticket.mode) {
                "root" -> root.start { allowed() }.also {
                    if (it == null) failure = root.status().reasonCode ?: "restoreBusy"
                }
                "sui", "shizuku" -> {
                    val facts = shizuku.status()
                    failure = when {
                        !facts.running -> "serviceUnavailable"
                        facts.provider != ticket.mode -> "providerChanged"
                        !facts.granted -> "permissionRequired"
                        else -> null
                    }
                    if (failure != null) { waiting = true; null }
                    else shizuku.connect(whenAvailable = { recoveryAvailable(ticket) }, mayStart = { allowed() })
                        .also { if (it == null) failure = "connectFailed" }
                }
                "adb" -> {
                    val facts = adb.status()
                    if (!facts.paired) { waiting = true; failure = "notPaired"; null }
                    else if (!wifiAvailable()) { waiting = true; failure = "networkUnavailable"; null }
                    else {
                        enableWirelessOnce(ticket, facts.wirelessDebugging)
                        adb.connect(whenAvailable = { recoveryAvailable(ticket) }, mayStart = { allowed() })
                            .also { if (it == null) failure = "connectFailed" }
                    }
                }
                else -> null
            }
            val connected = value?.takeIf { it.alive() }
            synchronized(this) {
                synchronized(keepGuard) {
                    if (selectionChange == null && allowed() && connected != null) {
                        previewChanged = replaceChannel(connected)
                        gate.connected(observed, connected)
                    }
                }
            }
            return value?.takeIf { allowed() && it.alive() }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return null
        } catch (_: Exception) {
            return null
        } finally {
            if (previewChanged) onPreviewChanged()
            val alive = value?.alive() == true
            synchronized(keepGuard) { keep.complete(ticket, alive, failure, waiting, SystemClock.elapsedRealtime()) }
            notifyChanged()
        }
    }

    /** Only a connect rejected by an older busy owner can register this one-shot callback. */
    private fun recoveryAvailable(ticket: PrivilegedKeepState.Ticket) {
        val run = synchronized(keepGuard) {
            if (!keep.current(ticket)) return
            if (restoring != null) { restoreAgain = true; false }
            else { keep.available(ticket); true }
        }
        if (run) restoreKeptChannel()
    }

    private fun transportChanged(source: String) {
        if (mode == source || source == "sharedApi" && mode in setOf("sui", "shizuku")) {
            recovery.execute {
                // Platform liveness checks stay outside the preview/controller monitors.
                val dead = previewTargets.values.filter { !it.channel.alive() }
                val removed = synchronized(previewGuard) {
                    val ids = dead.filter { previewTargets[it.taskId] === it }.map { it.taskId }
                    if (ids.isEmpty()) false else { previewTargets = previewTargets - ids.toSet(); true }
                }
                if (removed) onPreviewChanged()
            }
        }
        notifyChanged()
        if (keep.enabled && (mode == source || source == "sharedApi" && mode in setOf("sui", "shizuku")))
            restoreKeptChannel()
    }

    private fun wifiAvailable(): Boolean = runCatching {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
    }.getOrDefault(false)

    private fun enableWirelessOnce(ticket: PrivilegedKeepState.Ticket, wireless: Boolean?) {
        if (wireless == true || !secureSettingsGranted()) return
        if (runCatching { Settings.Global.getInt(app.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) }.getOrDefault(0) != 1) return
        if (keep.takeWirelessAttempt(ticket)) runCatching { Settings.Global.putInt(app.contentResolver, "adb_wifi_enabled", 1) }
    }

    private fun updateKeepListeners() {
        if (keep.enabled && mode in setOf("shizuku", "sui")) shizuku.ensureListeners()
        synchronized(networkGuard) {
            val cm = app.getSystemService(ConnectivityManager::class.java)
            if (keep.enabled && mode == "adb") {
                if (networkCallback == null) {
                    val callback = object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) {
                            notifyChanged()
                            val current = synchronized(networkGuard) { networkCallback === this }
                            if (current && keep.enabled && mode == "adb") restoreKeptChannel()
                        }
                        override fun onLost(network: Network) { notifyChanged() }
                    }
                    runCatching {
                        cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
                        networkCallback = callback
                    }
                }
            } else {
                networkCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
                networkCallback = null
            }
        }
    }

    companion object {
        /** Pure publication of journal state plus the controller's actual retained resource facts. */
        internal fun resourceRecoveryStatus(saved: BackgroundResourceJournal.Snapshot, running: Boolean,
            retiredPeer: Boolean, lostTask: Boolean, connectionReady: Boolean): Map<String, Any?> {
            val needsRecovery = retiredPeer || lostTask
            val state = if (running) "recovering" else if (needsRecovery && saved.state == "clear") "pending" else saved.state
            val canRetry = !running && (saved.storageRetry || needsRecovery || state == "pending" && connectionReady)
            return mapOf("v" to 1, "state" to state, "count" to saved.count, "canRetry" to canRetry,
                "reason" to (saved.reason ?: if (needsRecovery) "reconnectRequired" else null))
        }

        /** UserHandle.PER_USER_RANGE: a uid's user is uid / this. */
        private const val PER_USER_RANGE = 100_000

        @Volatile private var instance: BackgroundControl? = null
        fun get(context: Context): BackgroundControl =
            instance ?: synchronized(this) {
                instance ?: BackgroundControl(context).also { instance = it }
            }
    }
}
