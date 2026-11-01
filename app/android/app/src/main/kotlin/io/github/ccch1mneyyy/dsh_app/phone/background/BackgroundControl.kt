package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Process
import io.github.ccch1mneyyy.dsh_app.phone.PhoneRegistry
import java.util.concurrent.atomic.AtomicLong

/**
 * The 不打扰模式 surface the core's `PhonePlugin` calls into: the `background` block of `status`,
 * and the actions behind `setBackgroundMode`, `requestShizukuPermission`, `adbStartPairing`,
 * `adbPair`, `adbConnect`. It owns the two starters (Shizuku / self-ADB — both user-selectable),
 * probes whether a trusted virtual display and input injection work here, and registers
 * [BackgroundDisplay] in [PhoneRegistry] only while a task runs. Method names match the
 * `dsh/phone` channel.
 */
class BackgroundControl private constructor(context: Context) {
    private val app = context.applicationContext

    @Volatile var onStatusChanged: () -> Unit = {}

    private val shizuku = ShizukuStarter(app) { notifyChanged() }
    private val adb = AdbStarter(app) { notifyChanged() }

    @Volatile private var mode: String = "off"          // off | shizuku | adb
    @Volatile private var channel: PrivilegedChannel? = null
    @Volatile private var driver: BackgroundDisplay? = null
    @Volatile private var driverTaskId: Long? = null
    private val endedTaskId = AtomicLong(Long.MIN_VALUE)

    // Cached probe results (null = not probed this session).
    @Volatile private var trustedDisplayOk: Boolean? = null
    @Volatile private var injectOk: Boolean? = null

    private fun notifyChanged() = runCatching { onStatusChanged() }

    private fun androidOk(): Boolean = Build.VERSION.SDK_INT >= BackgroundPolicy.MIN_SDK

    // ---- status ------------------------------------------------------------

    /** The `background` sub-map of the `dsh/phone` `status` method. */
    fun status(): Map<String, Any?> {
        val reason = readiness()
        return mapOf(
            "mode" to mode,
            "ready" to (reason == null),
            "reason" to reason,
            "androidOk" to androidOk(),
            "trustedDisplay" to trustedDisplayOk,
            "inject" to injectOk,
            "shizuku" to shizuku.status().map(),
            "adb" to adb.status().map(),
        )
    }

    private val UNSUPPORTED: String get() = AppStrings.get(app, R.string.background_unsupported)

    private fun readiness(): String? = when {
        mode == "off" -> AppStrings.get(app, R.string.background_off)
        !androidOk() -> AppStrings.get(app, R.string.background_requires_android)
        mode == "shizuku" -> shizuku.reason() ?: if (trustedDisplayOk == false) UNSUPPORTED else null
        mode == "adb" -> adb.reason() ?: if (trustedDisplayOk == false) UNSUPPORTED else null
        else -> AppStrings.get(app, R.string.background_unknown_mode)
    }

    // ---- actions -----------------------------------------------------------

    fun setBackgroundMode(newMode: String): Map<String, Any?> {
        if (newMode !in setOf("off", "shizuku", "adb")) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_unknown_mode))
        if (newMode == "off") {
            endTask()
            disconnectAll()
            mode = "off"
            notifyChanged()
            return mapOf("ok" to true)
        }
        if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
        if (mode != newMode) {
            endTask()
            // A prepared ADB connection must not reuse the old Shizuku channel
            // (or vice versa) when the user enables the selected transport.
            channel = null
            if (mode == "shizuku") shizuku.disconnect()
            else if (mode == "adb") adb.disconnect()
            trustedDisplayOk = null
            injectOk = null
        }
        mode = newMode
        if (newMode == "shizuku") shizuku.ensureListeners()
        notifyChanged()
        // Probe eagerly so the UI can hide an unsupported switch rather than fail later.
        val probe = runGateProbe()
        return mapOf("ok" to (probe == null), "reason" to probe)
    }

    fun requestShizukuPermission(): Boolean = shizuku.requestPermission()

    fun adbStartPairing(): Map<String, Any?> {
        if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
        AdbPairingNotification.show(app)
        return adb.startPairing()
    }

    fun adbPair(code: String, port: Int?): Map<String, Any?> = adb.pair(code, port)

    fun adbConnect(port: Int? = null): Map<String, Any?> {
        if (!androidOk()) return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_requires_android))
        if (port != null && port !in 1..65535) {
            return mapOf("ok" to false, "reason" to AppStrings.get(app, R.string.background_adb_invalid_port))
        }
        // Prepare the transport before the user enables background control. Running
        // the mode/readiness gate here creates an off -> connect -> enable cycle.
        val connected = adb.connect(port) != null
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
        val shared = mode == via
        val ch = when {
            shared -> activeChannel()
            via == SecureSettingsGrant.SHIZUKU -> shizuku.connect()
            else -> adb.connect()
        }
        val request = Bundle().apply {
            putString(Proto.OP, Proto.OP_GRANT_SECURE_SETTINGS)
            putInt(Proto.USER, Process.myUid() / PER_USER_RANGE)
        }
        val ok = ch != null && runCatching { ch.execute(request).getBoolean(Proto.OK) }.getOrDefault(false)
        if (!shared) if (via == SecureSettingsGrant.SHIZUKU) shizuku.disconnect() else adb.disconnect()
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
        if (activeChannel() == null) return false
        synchronized(this) {
            if (mode == "off" || taskId <= endedTaskId.get() || (driverTaskId ?: Long.MIN_VALUE) > taskId) return false
            if (driverTaskId == taskId && driver != null && PhoneRegistry.backgroundDriver === driver) return true
            if (driver != null) endTask()
            val d = BackgroundDisplay { activeChannel() }.also { driver = it }
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

    /** Screen off / lock / channel death: stop and release. */
    fun interrupt() {
        endTask()
        disconnectAll()
    }

    // ---- channel plumbing --------------------------------------------------

    private fun activeChannel(): PrivilegedChannel? {
        channel?.takeIf { it.alive() }?.let { return it }
        channel = when (mode) {
            "shizuku" -> shizuku.connect()
            "adb" -> adb.connect()
            else -> null
        }
        return channel
    }

    private fun disconnectAll() {
        channel = null
        shizuku.disconnect()
        adb.disconnect()
    }

    private fun runGateProbe(): String? {
        val starterReason = when (mode) {
            "shizuku" -> shizuku.reason()
            "adb" -> adb.reason()
            else -> AppStrings.get(app, R.string.background_off)
        }
        if (starterReason != null) return starterReason
        val ch = activeChannel() ?: return AppStrings.get(app, R.string.background_not_ready)
        val response = runCatching {
            ch.execute(Bundle().apply { putString(Proto.OP, Proto.OP_GATE); putString(Proto.OWNER, "__gate__") })
        }.getOrNull() ?: return AppStrings.get(app, R.string.background_no_response)
        val ok = response.getBoolean(Proto.OK)
        trustedDisplayOk = ok
        injectOk = if (response.containsKey(Proto.INJECT_OK)) response.getBoolean(Proto.INJECT_OK) else null
        notifyChanged()
        return when {
            !ok -> UNSUPPORTED
            injectOk == false -> AppStrings.get(app, R.string.background_injection_denied)
            else -> null
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
