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
    @Volatile private var selectionChange: Any? = null
    private val keepPrefs = app.getSharedPreferences("phone-privileged-keep", Context.MODE_PRIVATE)
    private val keep = PrivilegedKeepState(keepPrefs.getString("keptMode", "off") ?: "off",
        PhoneControl.switchedOn(app), Build.VERSION.SDK_INT >= BackgroundPolicy.MIN_SDK)
    private val recovery = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-privileged-keep").apply { isDaemon = true } }
    // Pairing from the App and from the notification share one queue: an older attempt can't
    // stop a newer one's discovery, and its result can't replace the newer one's notification.
    private val pairing = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-adb-pair").apply { isDaemon = true } }
    private var restoring: FutureTask<PrivilegedChannel?>? = null
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
    private val taskResource = BackgroundTaskSlot<BackgroundDisplay>(this)
    // Lock order: this -> keepGuard -> previewGuard (either prefix may be omitted). Never IPC or a reverse lock under previewGuard.
    private val previewGuard = Any()
    @Volatile private var previewTarget: BackgroundPreviewTarget? = null
    @Volatile var onPreviewChanged: () -> Unit = {}

    fun previewTarget(): BackgroundPreviewTarget? = previewTarget

    private fun replaceChannel(value: PrivilegedChannel?) {
        val changed = synchronized(previewGuard) {
            if (channel === value) false else {
                channel = value
                previewTarget = null
                true
            }
        }
        if (changed) onPreviewChanged()
    }

    /** The callback belongs to the original record, not whichever task is selected now. */
    private fun publishPreviewTarget(record: BackgroundTaskSlot.TaskResource<BackgroundDisplay>, value: PrivilegedChannel) {
        val changed = synchronized(this) {
            synchronized(previewGuard) {
                val active = record.driver
                val taskId = record.owner.taskId
                if (!taskResource.current(record) || channel !== value || !active.previewAvailable(value)) false
                else if (previewTarget?.let { it.taskId == taskId && it.driver === active && it.channel === value } == true) false
                else { previewTarget = BackgroundPreviewTarget(taskId, active.ownerToken, value, active); true }
            }
        }
        if (changed) onPreviewChanged()
    }

    /** Called under the driver owner lock after sealing dispatch; no callback or IPC here. */
    private fun withdrawPreviewTarget(value: BackgroundDisplay): Boolean = synchronized(previewGuard) {
        if (previewTarget?.driver !== value) false
        else { previewTarget = null; true }
    }
    @Volatile private var interruptRequested = false
    @Volatile private var selectingResource = false
    private var interruptFinishing = false

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
        val state = if (running) "recovering" else if (retiredResourcePeer != null && saved.state == "clear") "pending" else saved.state
        val canRetry = !running && (saved.storageRetry || retiredResourcePeer != null ||
            state == "pending" && mode in PrivilegedKeepState.MODES && (channel?.alive() == true || keep.enabled))
        return mapOf("v" to 1, "state" to state, "count" to saved.count, "canRetry" to canRetry,
            "reason" to (saved.reason ?: if (retiredResourcePeer != null) "reconnectRequired" else null))
    }

    /** This ID comes from the still-retained original driver, never from a journal string. */
    internal fun pendingStoredTaskId(): Long? = taskResource.cleanupCandidate()
        ?.takeIf { it.driver.physicalComplete }?.owner?.taskId

    /** The sealed original whose pinned peer died before strict release. Liveness is read outside the monitor. */
    private fun lostTaskResource(): BackgroundTaskSlot.TaskResource<BackgroundDisplay>? = taskResource.cleanupCandidate()
        ?.takeIf { !it.driver.physicalComplete && it.driver.originalPeerLost }
    internal fun lostTaskId(): Long? = lostTaskResource()?.owner?.taskId

    /** Only a pure memory intent change belongs here; transport, callbacks and disk stay outside. */
    internal fun <T> changeGateIntent(change: () -> T): T {
        val original = gateCall
        val result = gate.changeIntent(change)
        if (original != null && !gate.current(original.probe)) original.io.seal()
        return result
    }

    internal fun retryStoredGateCleanup(): Boolean {
        val old = gateCall ?: return true
        if (!old.resource.physicalComplete) return false
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
        val lost = lostTaskResource()?.driver
        if (records.isEmpty() && retiredResourcePeer == null && lost == null) return null // Storage retry only; never retires a live current peer.
        if (!beginTransportUse(recoveryUse = true)) return "busy"
        try {
            val selection = synchronized(keepGuard) { keep.selectionTicket() }
            val pending = retiredResourcePeer
            val allowed = { !interruptRequested && selectionChange == null && keep.selectionCurrent(selection) }
            // A retained completed peer can be disconnected without reviving the old user's consent.
            val peer = pending?.peer ?: activeChannel(allowed, explicit = true, transportReserved = true)
                ?: return "connectionRequired"
            // Its occupied slot makes old-record recovery busy, so the lost original goes first.
            if (lost != null && pending == null) return recoverLostTask(lost, peer, allowed)
            return recoverResourceRecords(peer, selection, allowed, settingsUse = false)
        } finally {
            endTransportUse()
            if (keep.enabled) restoreKeptChannel()
        }
    }

    /** The sealed slot stays the fence. Only a different peer's exact absence receipt completes the
     * drained original scope; endTask then returns the slot and registry leases by the normal path.
     */
    private fun recoverLostTask(lost: BackgroundDisplay, peer: PrivilegedChannel, mayStart: () -> Boolean): String? = try {
        val cap = peer.execute(Bundle().apply { putString(Proto.OP, Proto.OP_PROBE) }) {
            check(mayStart()) { "selectionChanged" }
        }
        val birth = if ((cap.get(Proto.OK) as? Boolean) == true) BackgroundRecoveryProtocol.birth(cap::get) else null
        val verified = birth != null && lost.recoverLostPeer { saved ->
            if (saved.birth.peer == birth.peer || !mayStart()) false
            else {
                val reply = peer.execute(BackgroundRecoveryProtocol.check(saved)) { check(mayStart()) { "selectionChanged" } }
                BackgroundRecoveryProtocol.recovered(saved, reply::get, reply::containsKey)
            }
        }
        // A completed physical proof whose durable clear failed is retried by endTask.
        if (birth == null) "connectionRequired" else if (verified || lost.physicalComplete) null else "recoveryUnknown"
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
            val birth = BackgroundRecoveryProtocol.birth(cap::get) ?: return "recoveryUnsupported"
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
                else { channel = null; previewTarget = null; true }
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
        return current.status(current.peer.alive())
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
            cached.injectOk == false -> Reasons.withDetail(inputFailureReason(
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

    // ---- actions -----------------------------------------------------------

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
                    if (changing) taskResource.seal()?.driver?.seal()
                }
            }
            try {
                // Do not change the selected transport while its original resource remains unconfirmed.
                if (changing && !endTask()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.phone_background_cleanup_before_switch))
                val (selection, transition) = synchronized(keepGuard) {
                    if (!mayStart() || selectionChange != null) return keepFailure("selectionChanged")
                    val leaving = if (mode == "sui") "shizuku" else mode
                    val owner = if (changing) Any().also { selectionChange = it } else null
                    keep.select(selected)
                    rootSelected = selected == "root"
                    if (changing) replaceChannel(null)
                    keep.selectionTicket() to owner?.let { it to leaving }
                }
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
                        synchronized(keepGuard) { if (allowed()) replaceChannel(connected) }
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

    /** Root for the WSS grant only: 不打扰模式's mode and display stay as they are. */
    fun prepareRoot(mayStart: () -> Boolean): Map<String, Any?> {
        if (!beginTransportUse()) return transportBusy()
        try {
            rootSelected = true
            return if (root.start(mayStart) != null) mapOf("ok" to true) else mapOf("ok" to false, "reason" to rootReason())
        } finally { endTransportUse() }
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
        try {
            if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
            if (port != null && port !in 1..65535) {
                return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_adb_invalid_port))
            }
            // Prepare the transport before the user enables background control. Running
            // the mode/readiness gate here creates an off -> connect -> enable cycle.
            val connected = adb.connect(port, mayStart = mayStart) != null
            notifyChanged()
            return mapOf("ok" to connected, "reason" to if (connected) null else adb.reason())
        } finally { endTransportUse() }
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
                shared -> activeChannel(mayStart)
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

    /** Returns this Owner's driver directly; another task's resource is never displaced. */
    fun driverForTask(owner: PhoneTasks.Owner, currentOwner: () -> Boolean,
                      admitOwner: ((() -> Unit) -> Boolean)): BackgroundDisplay? {
        fun current() = currentOwner() && !Thread.currentThread().isInterrupted
        if (mode == "off" || !androidOk() || resourceAdmission() != null) return null
        val selection = synchronized(this) {
            if (resourceMaintenance != null || retiredResourcePeer != null || selfCheckBorrow != null || gateCall != null || gate.needsRetest || selectingResource || interruptRequested || !current()) return null
            taskResource.find(owner)?.let { return it.driver }
            if (taskResource.occupied) return null
            keep.selectionTicket()
        }
        fun allowed() = current() && keep.selectionCurrent(selection)
        // Setup can block; stop/cleanup must still be able to enter the ownership monitor.
        if (keep.enabled) {
            try { restoreKeptChannel()?.get() } catch (_: InterruptedException) {
                Thread.currentThread().interrupt(); return null
            } catch (_: Exception) { return null }
        }
        if (!allowed() || activeChannel(mayStart = ::allowed) == null) return null
        val acquired = synchronized(this) {
            if (resourceMaintenance != null || retiredResourcePeer != null || selfCheckBorrow != null || gateCall != null || gate.needsRetest || selectingResource || interruptRequested || mode == "off") return null
            lateinit var record: BackgroundTaskSlot.TaskResource<BackgroundDisplay>
            record = taskResource.acquire(owner, ::allowed) {
                // Construction has no platform work. A concurrent stop either invalidates
                // current before admission, or seals this published record after this monitor.
                BackgroundDisplay(
                    channelProvider = { activeChannel() },
                    journal = resourceJournal,
                    mayUse = { currentOwner() && !interruptRequested },
                    admitUse = { action -> admitOwner {
                        check(!interruptRequested)
                        action()
                    } },
                    viewport = viewport,
                    onResourceReady = { publishPreviewTarget(record, it) },
                )
            } ?: return null
            record
        }
        notifyChanged()
        return acquired.driver
    }

    /** Immediately seals dispatch; it never waits for platform I/O. Null explicitly means all. */
    fun sealTask(expectedTaskId: Long? = null) {
        val changed = synchronized(this) {
            taskResource.seal(expectedTaskId)?.driver?.let { it.seal(); withdrawPreviewTarget(it) } ?: false
        }
        if (changed) onPreviewChanged()
    }

    /** Capture the original record, release outside the lock, then commit by record identity. */
    fun endTask(expectedTaskId: Long? = null): Boolean {
        var previewChanged = false
        val captured = synchronized(this) {
            val record = taskResource.seal(expectedTaskId) ?: return true
            record.driver.seal()
            previewChanged = withdrawPreviewTarget(record.driver)
            record
        }
        if (previewChanged) onPreviewChanged()
        if (!captured.driver.release()) return false
        if (!taskResource.complete(captured)) return false
        notifyChanged()
        finishInterrupt()
        return true
    }

    /** Screen-off withdraws dispatch immediately; disconnection follows exact physical cleanup. */
    fun requestInterrupt() {
        val changed = synchronized(this) {
            gate.changeIntent { interruptRequested = true }
            synchronized(keepGuard) { gateCall?.io?.seal() }
            taskResource.seal()?.driver?.let { it.seal(); withdrawPreviewTarget(it) } ?: false
        }
        if (changed) onPreviewChanged()
    }

    fun finishInterrupt() {
        synchronized(this) {
            if (!interruptRequested || interruptFinishing || taskResource.occupied || selectingResource) return
            synchronized(keepGuard) {
                if (resourceMaintenance != null || retiredResourcePeer != null || selfCheckBorrow != null || gateCall != null || transportUsers != 0 || restoring != null || selectionChange != null) return
                interruptFinishing = true
            }
        }
        // A single claimant disconnects outside the owner lock. No task/keep borrower may
        // publish during this interval, including callbacks caused by disconnect itself.
        try {
            disconnectAll(PrivilegedPathPolicy::closesOnInterrupt)
            synchronized(this) { interruptRequested = false }
        } finally {
            synchronized(this) { interruptFinishing = false }
            notifyChanged()
        }
    }

    // ---- channel plumbing --------------------------------------------------

    private fun activeChannel(mayStart: () -> Boolean = { true }, explicit: Boolean = false,
                              transportReserved: Boolean = false): PrivilegedChannel? {
        if (!transportReserved && !beginTransportUse()) return null
        try {
            if (!mayStart() || interruptRequested) return null
            val (selection, cached) = synchronized(keepGuard) {
                if (selectionChange != null) return null
                keep.selectionTicket() to channel
            }
            // Starter guards may call this; only volatile reads, never keepGuard acquisition.
            val allowed = { mayStart() && !interruptRequested && selectionChange == null && keep.selectionCurrent(selection) }
            val selected = selection.mode
            // Disabling keep does not authorize a different shared-API provider.
            if ((selected == "shizuku" || selected == "sui") && shizuku.status().provider != selected) return null
            val observed = gate.snapshot
            if (cached?.alive() == true) return synchronized(keepGuard) {
                if (!allowed() || channel !== cached) null
                else { gate.connected(observed, cached); cached }
            }
            if (!allowed() || (keep.enabled && !explicit)) return null
            val connected = when (selected) {
                "shizuku", "sui" -> shizuku.connect(mayStart = allowed)
                "root" -> root.connect()
                "adb" -> adb.connect(mayStart = allowed)
                else -> null
            } ?: return null
            return synchronized(keepGuard) {
                if (!allowed()) null
                else { replaceChannel(connected); gate.connected(observed, connected); connected }
            }
        } finally { if (!transportReserved) endTransportUse() }
    }

    private fun disconnectAll(closes: (String) -> Boolean = { true }) {
        synchronized(keepGuard) { replaceChannel(null) }
        disconnectTransports(closes)
    }

    private fun disconnectTransports(closes: (String) -> Boolean) {
        if (closes("shizuku")) shizuku.disconnect()
        if (closes("adb")) adb.disconnect()
        if (closes("root")) root.disconnect()
    }

    /** Settings owns one outer transport use. The original resource survives a cancelled UI. */
    private fun runGateProbe(selection: PrivilegedKeepState.Ticket, mayStart: () -> Boolean): String? {
        val starterReason = when (mode) {
            "shizuku", "sui" -> shizuku.reason()
            "root" -> rootReason()
            "adb" -> adb.reason()
            else -> AppStrings.get(app, R.string.background_off)
        }
        if (starterReason != null) return starterReason
        var peer = activeChannel(mayStart, explicit = true, transportReserved = true)
            ?: return AppStrings.get(app, R.string.background_not_ready)
        if (recoverResourceRecords(peer, selection, mayStart, settingsUse = true) != null)
            return AppStrings.get(app, R.string.background_resource_recovery_pending)
        if (!peer.alive()) {
            // runGateProbe is reached only from the user's existing explicit setBackgroundMode.
            if (selection.mode == "root" && mayStart()) root.start(mayStart)?.let { fresh ->
                synchronized(keepGuard) { if (mayStart()) replaceChannel(fresh) }
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
                    (cap.get(Proto.RELEASE_RECEIPT) as? Int) != 1) {
                    reason = failed(R.string.background_gate_peer_unsupported, peer)
                    return@call
                }
                val birth = BackgroundRecoveryProtocol.birth(cap::get)
                if (birth == null) { reason = failed(R.string.background_gate_peer_unsupported, peer); return@call }
                if (!call.resource.begin(birth)) { reason = AppStrings.get(app, R.string.background_resource_recovery_pending); return@call }
                val allocation = OwnerScopeProtocol.first(call.io, peer,
                    BackgroundRecoveryProtocol.allocate(call.io.owner, "probe", null)) { commit -> gate.admit(probe, commit) }
                val actualId = BackgroundRecoveryProtocol.allocationId(allocation::get)
                if (actualId == null || !call.resource.allocated(actualId) { gate.current(probe) && !call.io.previewClosed() }) {
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
                    published = if (receipt.trustedDisplayOk && receipt.injectOk == true)
                        gate.completedWithCleanup(probe) else gate.current(probe)
                }
            }
        }
        if (!released) return AppStrings.get(app, R.string.background_gate_cleanup_pending)
        if (accepted != null && !published) return AppStrings.get(app, R.string.background_selection_cancelled)
        return if (accepted != null) reason else reason ?: AppStrings.get(app, R.string.background_no_response)
    }

    /** Retry has no new admission/connect/probe and does not require the old UI to remain attached. */
    fun retryGateCleanup(handle: String): Map<String, Any?> {
        val call = synchronized(keepGuard) {
            gateCall?.takeIf { it.handle == handle }
        } ?: return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_gate_cleanup_stale))
        if (!call.peer.alive() && !call.resource.physicalComplete) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_gate_cleanup_pending))
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

    /** Foreground/start/BOOT hook. No UI permission request and no display/input gate. */
    fun restoreKeptChannel(): Future<PrivilegedChannel?>? {
        if (interruptRequested || !PhoneControl.switchedOn(app) || !androidOk() || !keep.enabled) return null
        updateKeepListeners()
        synchronized(keepGuard) {
            // The switch's finally retries after cleanup, including a keep saved during the switch.
            if (resourceMaintenance != null || retiredResourcePeer != null || interruptRequested || selectingResource || gateCall != null || selectionChange != null || selfCheckBorrow != null) return null
            restoring?.let {
                if (restoringTicket?.let(keep::current) != true) restoreAgain = true
                return it
            }
            val ticket = keep.begin(SystemClock.elapsedRealtime()) ?: return null
            val task = FutureTask { restore(ticket) }
            restoring = task
            restoringTicket = ticket
            recovery.execute {
                try { task.run() } finally {
                    val again = synchronized(keepGuard) {
                        restoring = null; restoringTicket = null
                        restoreAgain.also { restoreAgain = false }
                    }
                    finishInterrupt()
                    // A newer keep generation, or a starter this one found busy, asked meanwhile.
                    if (again) {
                        synchronized(keepGuard) { keep.available(ticket) }
                        restoreKeptChannel()
                    }
                }
            }
            return task
        }
    }

    private fun restore(ticket: PrivilegedKeepState.Ticket): PrivilegedChannel? {
        val observed = gate.snapshot
        var failure: String? = "connectFailed"
        var waiting = false
        var value: PrivilegedChannel? = null
        fun allowed() = !interruptRequested && !selectingResource && gateCall == null && keep.current(ticket)
        try {
            if (!allowed()) return null
            value = when (ticket.mode) {
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
                    else shizuku.connect(whenAvailable = { recoveryAvailable(ticket) }, mayStart = { allowed() }).also { if (it == null) failure = "connectFailed" }
                }
                "adb" -> {
                    val facts = adb.status()
                    if (!facts.paired) { waiting = true; failure = "notPaired"; null }
                    else if (!wifiAvailable()) { waiting = true; failure = "networkUnavailable"; null }
                    else {
                        enableWirelessOnce(ticket, facts.wirelessDebugging)
                        adb.connect(whenAvailable = { recoveryAvailable(ticket) }, mayStart = { allowed() }).also { if (it == null) failure = "connectFailed" }
                    }
                }
                else -> null
            }
            // Starter publication owns successful channels. A stale borrower must never close one.
            val connected = value?.takeIf { it.alive() }
            synchronized(keepGuard) {
                if (selectionChange == null && allowed() && connected != null) {
                    replaceChannel(connected)
                    gate.connected(observed, connected)
                }
            }
            return value?.takeIf { allowed() && it.alive() }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return null
        } catch (_: Exception) {
            return null
        } finally {
            val alive = value?.alive() == true
            synchronized(keepGuard) {
                keep.complete(ticket, alive, failure, waiting, SystemClock.elapsedRealtime())
            }
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
                val previous = previewTarget
                if (previous != null && !previous.channel.alive()) {
                    val removed = synchronized(previewGuard) {
                        if (previewTarget !== previous) false else { previewTarget = null; true }
                    }
                    if (removed) onPreviewChanged()
                }
            }
        }
        notifyChanged()
        // These callbacks may run on main; startup/PROBE always run on recovery's single slot.
        if (keep.enabled && (mode == source || source == "sharedApi" && mode in setOf("sui", "shizuku"))) restoreKeptChannel()
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
        /** UserHandle.PER_USER_RANGE: a uid's user is uid / this. */
        private const val PER_USER_RANGE = 100_000

        @Volatile private var instance: BackgroundControl? = null
        fun get(context: Context): BackgroundControl =
            instance ?: synchronized(this) {
                instance ?: BackgroundControl(context).also { instance = it }
            }
    }
}
