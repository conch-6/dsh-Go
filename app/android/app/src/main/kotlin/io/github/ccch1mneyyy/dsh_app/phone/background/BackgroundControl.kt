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
import io.github.ccch1mneyyy.dsh_app.phone.PhoneRegistry
import java.util.concurrent.atomic.AtomicLong

/**
 * The 不打扰模式 surface the core's `PhonePlugin` calls into: the `background` block of `status`,
 * and the actions behind `setBackgroundMode`, `requestShizukuPermission`, `adbStartPairing`,
 * `adbPair`, `adbConnect`. It owns the shared Shizuku/Sui, self-ADB and explicit root starters,
 * probes whether a trusted virtual display and input injection work here, and registers
 * [BackgroundDisplay] in [PhoneRegistry] only while a task runs. Method names match the
 * `dsh/phone` channel.
 */
class BackgroundControl private constructor(context: Context) {
    private val app = context.applicationContext

    @Volatile var onStatusChanged: () -> Unit = {}

    private val keepGuard = Any()
    private val preferenceGuard = Any()
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

    private val shizuku = ShizukuStarter(app) { transportChanged("sharedApi") }
    private val adb = AdbStarter(app) { transportChanged("adb") }
    private val root = RootStarter(app) { transportChanged("root") }

    private val mode: String get() = keep.mode
    @Volatile private var rootSelected = mode == "root"
    @Volatile private var channel: PrivilegedChannel? = null
    @Volatile private var driver: BackgroundDisplay? = null
    @Volatile private var driverTaskId: Long? = null
    private val endedTaskId = AtomicLong(Long.MIN_VALUE)

    // Cached probe results (null = not probed this session).
    @Volatile private var trustedDisplayOk: Boolean? = null
    @Volatile private var injectOk: Boolean? = null
    @Volatile private var injectError: String? = null
    @Volatile private var gateDetail: String? = null

    private fun notifyChanged() = runCatching { onStatusChanged() }

    private fun androidOk(): Boolean = Build.VERSION.SDK_INT >= BackgroundPolicy.MIN_SDK

    // ---- status ------------------------------------------------------------

    /** The `background` sub-map of the `dsh/phone` `status` method. */
    fun status(): Map<String, Any?> {
        val reason = readiness()
        val shizukuStatus = shizuku.status()
        val adbStatus = adb.status()
        val rootStatus = root.status()
        return mapOf(
            "mode" to PrivilegedPathPolicy.legacyMode(mode),
            "ready" to PrivilegedPathPolicy.legacyReady(mode, reason == null),
            "reason" to PrivilegedPathPolicy.legacyReason(
                mode, reason, AppStrings.get(app, R.string.background_root_legacy_client),
            ),
            "androidOk" to androidOk(),
            "trustedDisplay" to trustedDisplayOk,
            "inject" to injectOk,
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

    private fun readiness(): String? = when {
        mode == "off" -> AppStrings.get(app, R.string.background_off)
        !androidOk() -> AppStrings.get(app, R.string.background_requires_android)
        mode == "shizuku" || mode == "sui" -> shizuku.reason() ?: gateReason()
        mode == "root" -> rootReason() ?: gateReason()
        mode == "adb" -> adb.reason() ?: gateReason()
        else -> AppStrings.get(app, R.string.background_unknown_mode)
    }

    private fun gateReason(): String? = when {
        trustedDisplayOk == false -> Reasons.withDetail(UNSUPPORTED, gateDetail)
        injectOk == false -> Reasons.withDetail(AppStrings.get(app, when (injectError) {
            "inputApiUnavailable" -> R.string.background_input_api_unavailable
            "systemOperationDenied" -> R.string.background_input_permission_denied
            else -> R.string.background_injection_denied
        }), gateDetail)
        else -> null
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

    // ---- actions -----------------------------------------------------------

    fun setBackgroundMode(newMode: String, mayStart: () -> Boolean = { true }): Map<String, Any?> {
        val provider = shizuku.status().provider
        val selected = PrivilegedPathPolicy.canonicalMode(newMode, provider)
            ?: return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_unknown_mode))
        if (selected == "sui" && provider != ShizukuStatus.SUI) {
            return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_sui_not_provider))
        }
        if (selected != "off" && !androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
        if (selected != mode || selected == "off") {
            endTask()
            // Only the transport being left closes: a paired ADB connection or a root process
            // prepared ahead belongs to the mode being enabled. Off closes everything.
            val leaving = if (mode == "sui") "shizuku" else mode
            disconnectAll { selected == "off" || it == leaving }
            trustedDisplayOk = null
            injectOk = null
            injectError = null
            gateDetail = null
        }
        synchronized(keepGuard) { keep.select(selected); rootSelected = selected == "root" }
        val cleared = synchronized(preferenceGuard) {
            keep.keptMode != "off" || keepPrefs.edit().putString("keptMode", "off").commit()
        }
        updateKeepListeners()
        if (!cleared) { notifyChanged(); return keepFailure("persistenceFailed") }
        when (selected) {
            "off" -> { notifyChanged(); return mapOf("ok" to true) }
            "shizuku", "sui" -> shizuku.ensureListeners()
            // 不打扰模式's only su; tasks just connect() to what it leaves.
            "root" -> root.start(mayStart)?.let { if (mayStart() && mode == "root") channel = it }
        }
        notifyChanged()
        if (!mayStart()) return keepFailure("selectionChanged")
        // Probe eagerly so the UI can hide an unsupported switch rather than fail later.
        val probe = runGateProbe(mayStart)
        return mapOf("ok" to (probe == null), "reason" to probe)
    }

    fun requestShizukuPermission(provider: String? = null): Boolean =
        (provider == null || provider == shizuku.status().provider) && shizuku.requestPermission()

    /** Root for the WSS grant only: 不打扰模式's mode and display stay as they are. */
    fun prepareRoot(mayStart: () -> Boolean): Map<String, Any?> {
        rootSelected = true
        return if (root.start(mayStart) != null) mapOf("ok" to true) else mapOf("ok" to false, "reason" to rootReason())
    }

    fun rootGrantSelected(): Boolean = rootSelected

    /** Detach invalidates only the caller's unpublished UI attempt, not borrowed healthy channels. */
    fun cancelUnwantedPending() {
        root.cancelUnwantedPending()
        shizuku.cancelUnwantedPending()
        adb.cancelUnwantedPending()
    }

    fun cancelRootSelection() {
        rootSelected = false
        root.disconnect()
    }

    private fun secureSettingsGranted(): Boolean =
        app.checkSelfPermission(SecureSettingsGrant.PERMISSION) == PackageManager.PERMISSION_GRANTED

    /** The RPC result isn't the answer: the permission itself is. An existing root connection is required. */
    fun grantRootSecureSettings(): Map<String, Any?> {
        if (secureSettingsGranted()) return mapOf("ok" to true)
        val ran = root.grantSecureSettings()
        if (secureSettingsGranted()) return mapOf("ok" to true)
        return mapOf("ok" to false, "reason" to ((if (ran) null else rootReason()) ?: AppStrings.get(app, R.string.background_root_grant_failed)))
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
        if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
        if (port != null && port !in 1..65535) {
            return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_adb_invalid_port))
        }
        // Prepare the transport before the user enables background control. Running
        // the mode/readiness gate here creates an off -> connect -> enable cycle.
        val connected = adb.connect(port, mayStart = mayStart) != null
        notifyChanged()
        return mapOf("ok" to connected, "reason" to if (connected) null else adb.reason())
    }

    // ---- 自动恢复无障碍 (WRITE_SECURE_SETTINGS through the engine) -------------

    /** The one-tap way to the permission right now ([SecureSettingsGrant.path]). */
    fun grantPath(granted: Boolean): String =
        if (granted) SecureSettingsGrant.GRANTED else SecureSettingsGrant.path(false, shizuku.status(), adb.status())

    /**
     * Has the engine grant the permission over [via] (`shizuku` / `adb`): 不打扰模式's channel when it
     * uses the same starter, else one opened for this and closed after. Blocks (an adb connect can
     * take seconds); true when the engine says it granted.
     */
    fun grantSecureSettings(via: String): Boolean {
        val sharedApi = via == SecureSettingsGrant.SHIZUKU || via == SecureSettingsGrant.SUI
        val shared = PrivilegedPathPolicy.sharesGrantChannel(mode, via)
        val ch = when {
            shared -> activeChannel()
            sharedApi -> shizuku.connect()
            else -> adb.connect()
        }
        val request = Bundle().apply {
            putString(Proto.OP, Proto.OP_GRANT_SECURE_SETTINGS)
            putInt(Proto.USER, Process.myUid() / PER_USER_RANGE)
        }
        val ok = ch != null && runCatching { ch.execute(request).getBoolean(Proto.OK) }.getOrDefault(false)
        if (!shared) if (sharedApi) shizuku.disconnectIfCurrent(ch) else adb.disconnectIfCurrent(ch)
        return ok
    }

    fun requestShizukuPermission(then: () -> Unit): Boolean = shizuku.requestPermission(then)

    // ---- task lifecycle (called by the bridge/core) ------------------------

    /** Connects, probes the gate, and registers the driver for the running task. */
    fun beginTask(taskId: Long): Boolean {
        if (mode == "off" || !androidOk()) return false
        synchronized(this) {
            if (taskId <= endedTaskId.get() || (driverTaskId ?: Long.MIN_VALUE) > taskId) return false
            if (driverTaskId == taskId && driver != null && PhoneRegistry.backgroundDriver === driver) return true
        }
        // Channel setup may block. It must not hold the display ownership lock
        // while an old task is trying to release through an already-live channel.
        if (keep.enabled) {
            try { restoreKeptChannel()?.get() } catch (_: InterruptedException) {
                Thread.currentThread().interrupt(); return false
            } catch (_: Exception) { return false }
        }
        if (Thread.currentThread().isInterrupted || activeChannel() == null) return false
        synchronized(this) {
            if (mode == "off" || taskId <= endedTaskId.get() || (driverTaskId ?: Long.MIN_VALUE) > taskId) return false
            if (driverTaskId == taskId && driver != null && PhoneRegistry.backgroundDriver === driver) return true
            if (driver != null) endTask()
            val d = BackgroundDisplay(
                channelProvider = { activeChannel() },
                releaseChannelProvider = { channel?.takeIf { it.alive() } },
            ).also { driver = it }
            // Publish the pending owner before checking cancellation: a stop
            // either records the ended ID first, or sees this owner and releases
            // it after the remaining registration (which performs no setup IPC).
            driverTaskId = taskId
            if (taskId <= endedTaskId.get()) {
                driver = null
                driverTaskId = null
                return false
            }
            PhoneRegistry.backgroundDriver = d
            notifyChanged()
            return true
        }
    }

    /** Releases the display without destroying content (handoff) and unregisters the driver. */
    fun endTask(expectedTaskId: Long? = null) {
        if (expectedTaskId != null) {
            endedTaskId.accumulateAndGet(expectedTaskId) { previous, ended -> maxOf(previous, ended) }
            // In-flight setup has no display to release. Do not make the stop
            // caller wait for its synchronous IPC; beginTask checks this ID.
            if (expectedTaskId != driverTaskId) return
        }
        synchronized(this) {
            if (expectedTaskId != null && expectedTaskId != driverTaskId) return
            val ended = driver
            driver = null
            driverTaskId = null
            if (PhoneRegistry.backgroundDriver === ended) PhoneRegistry.backgroundDriver = null
            ended?.release()
            notifyChanged()
        }
    }

    /**
     * Screen off / lock / channel death: stop and release, and drop the channels a later task
     * reopens by itself ([PrivilegedPathPolicy.closesOnInterrupt]; root's would need su again).
     */
    fun interrupt() {
        endTask()
        disconnectAll(PrivilegedPathPolicy::closesOnInterrupt)
    }

    // ---- channel plumbing --------------------------------------------------

    private fun activeChannel(mayStart: () -> Boolean = { true }, explicit: Boolean = false): PrivilegedChannel? {
        if (!mayStart()) return null
        channel?.takeIf { it.alive() }?.let { return it }
        if (keep.enabled && !explicit) return null
        channel = when (mode) {
            "shizuku", "sui" -> shizuku.connect(mayStart = mayStart)
            "root" -> root.connect()
            "adb" -> adb.connect(mayStart = mayStart)
            else -> null
        }
        return channel
    }

    private fun disconnectAll(closes: (String) -> Boolean = { true }) {
        channel = null
        if (closes("shizuku")) shizuku.disconnect()
        if (closes("adb")) adb.disconnect()
        if (closes("root")) root.disconnect()
    }

    private fun runGateProbe(mayStart: () -> Boolean): String? {
        val starterReason = when (mode) {
            "shizuku", "sui" -> shizuku.reason()
            "root" -> rootReason()
            "adb" -> adb.reason()
            else -> AppStrings.get(app, R.string.background_off)
        }
        if (starterReason != null) return starterReason
        val ch = activeChannel(mayStart, explicit = true) ?: return AppStrings.get(app, R.string.background_not_ready)
        val response = runCatching {
            ch.execute(Bundle().apply { putString(Proto.OP, Proto.OP_GATE); putString(Proto.OWNER, "__gate__") })
        }.getOrNull() ?: return AppStrings.get(app, R.string.background_no_response)
        val ok = response.getBoolean(Proto.OK)
        trustedDisplayOk = ok
        injectOk = if (response.containsKey(Proto.INJECT_OK)) response.getBoolean(Proto.INJECT_OK) else null
        injectError = if (injectOk == false) response.getString(Proto.INJECT_ERROR) else null
        gateDetail = response.getString(Proto.ERROR_DETAIL)
        notifyChanged()
        return gateReason()
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
            else keep.configure(if (enabled) selected else "off")
        } ?: return null to "selectionChanged"
        cancelUnwantedPending()
        if (!enabled) { updateKeepListeners(); PrivilegedKeepJob.cancel(app) }
        notifyChanged()
        return ticket to null
    }

    /** A previously disabled phone must not revive an old persisted keep on the next process start. */
    internal fun preparePhoneEnable(): Boolean = PhoneControl.switchedOn(app) || saveKeep(clearKeep())["ok"] == true

    internal fun clearKeepForMode(requested: String): PrivilegedKeepState.Ticket? {
        val selected = PrivilegedPathPolicy.canonicalMode(requested, shizuku.status().provider)
        return if (selected != mode || selected == "off") clearKeep() else null
    }

    /** Called immediately on mode/off intents, before any queued or blocked transport operation. */
    internal fun clearKeep(): PrivilegedKeepState.Ticket {
        val ticket = synchronized(keepGuard) { keep.configure("off") }
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
        if (!PhoneControl.switchedOn(app) || !androidOk() || !keep.enabled) return null
        updateKeepListeners()
        synchronized(keepGuard) {
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
        var failure: String? = "connectFailed"
        var waiting = false
        var value: PrivilegedChannel? = null
        try {
            if (!keep.current(ticket)) return null
            value = when (ticket.mode) {
                "root" -> root.start { keep.current(ticket) }.also {
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
                    else shizuku.connect(whenAvailable = { recoveryAvailable(ticket) }, mayStart = { keep.current(ticket) }).also { if (it == null) failure = "connectFailed" }
                }
                "adb" -> {
                    val facts = adb.status()
                    if (!facts.paired) { waiting = true; failure = "notPaired"; null }
                    else if (!wifiAvailable()) { waiting = true; failure = "networkUnavailable"; null }
                    else {
                        enableWirelessOnce(ticket, facts.wirelessDebugging)
                        adb.connect(whenAvailable = { recoveryAvailable(ticket) }, mayStart = { keep.current(ticket) }).also { if (it == null) failure = "connectFailed" }
                    }
                }
                else -> null
            }
            // Starter publication owns successful channels. A stale borrower must never close one.
            synchronized(keepGuard) { if (keep.current(ticket) && value?.alive() == true) channel = value }
            return value?.takeIf { keep.current(ticket) && it.alive() }
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
