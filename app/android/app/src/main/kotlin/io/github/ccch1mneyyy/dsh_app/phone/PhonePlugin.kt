package io.github.ccch1mneyyy.dsh_app.phone

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.github.ccch1mneyyy.dsh_app.phone.a11y.OverlayPrefs
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/**
 * Flutter bridge for phone control: MethodChannel `dsh/phone`, EventChannel `dsh/phone/events`.
 * Anything that may block runs off the main thread.
 */
class PhonePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, PluginRegistry.NewIntentListener {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var appContext: Context
    private lateinit var control: PhoneControl
    private var activity: ActivityPluginBinding? = null
    private var sink: ((Map<String, Any?>) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-phone-plugin").apply { isDaemon = true } }
    @Volatile private var promptOwner = Any()
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        control = PhoneControl.get(appContext)
        promptOwner = Any()
        attached = true
        methods = MethodChannel(binding.binaryMessenger, "dsh/phone").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dsh/phone/events").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        control.prompts.detachOwner(promptOwner)
        activity?.removeOnNewIntentListener(this)
        activity = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink?.let { control.removeSink(it) }
        sink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
        control.prompts.attachActivity(promptOwner, binding.activity)
        control.prompts.handleOpenIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeOnNewIntentListener(this)
        control.prompts.attachActivity(promptOwner, null)
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean = attached && control.prompts.handleOpenIntent(intent)

    /** Runs [block] on the plugin thread and answers on the main thread. */
    private fun async(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            val value = try {
                Result.success(block())
            } catch (e: Throwable) {
                Result.failure(e)
            }
            main.post {
                value.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("phone_failed", it.message ?: it.javaClass.simpleName, null) },
                )
            }
        }
    }

    private fun startActivity(intent: Intent): Boolean {
        val host = activity?.activity
        return try {
            if (host != null) host.startActivity(intent) else appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> async(result) { control.status() }
            "grantSecureSettings" -> async(result) { control.grantSecureSettings() }
            "setEnabled" -> async(result) { control.setEnabled(call.argument<Boolean>("enabled") == true) }
            "openAccessibilitySettings" -> result.success(startActivity(control.accessibilitySettingsIntent()))
            "openAppDetails" -> result.success(startActivity(control.appDetailsIntent()))
            "testScreen" -> async(result) { control.testScreen() }
            "setBackgroundMode" -> async(result) { control.background.setBackgroundMode(call.argument<String>("mode") ?: "off") }
            "requestShizukuPermission" -> async(result) { control.background.requestShizukuPermission() }
            "adbStartPairing" -> async(result) { control.background.adbStartPairing() }
            "adbPair" -> async(result) {
                val code = call.argument<String>("code")?.trim().orEmpty()
                if (code.isEmpty()) mapOf("ok" to false, "reason" to AppStrings.get(appContext, R.string.pairing_enter_code_error)) else control.background.adbPair(code, call.argument<Int>("port"))
            }
            "adbConnect" -> async(result) { control.background.adbConnect(call.argument<Int>("port")) }
            "getPolicies" -> async(result) { control.policiesMap() }
            "setPolicies" -> async(result) { control.setPolicies(call.arguments as? Map<*, *>) }
            "actionLog" -> result.success(control.log.toMaps(call.argument<Int>("limit") ?: 100))
            // l10n:keep agent stop reason
            "stopTask" -> result.success(control.stopTask("用户在 App 里停止"))
            "finishTask" -> finishTask(call, result)
            "presentPrompt" -> {
                val owner = promptOwner
                val request = EnginePhonePrompt.parse(call.arguments as? Map<*, *>)
                if (!attached) result.success(PhonePrompts.unavailable("stale"))
                else if (request == null) result.success(PhonePrompts.unavailable("invalid"))
                else control.prompts.present(request, owner, { attached && promptOwner === owner }) {
                    if (attached && promptOwner === owner) result.success(it)
                }
            }
            "cancelPrompt" -> {
                val id = call.argument<String>("requestId")
                result.success(id != null && id.length in 1..200 && control.prompts.cancel(id))
            }
            // 设置 → 手机操控 → 悬浮条: {idleOpacity 0.3–1, autoCollapse}; a showing overlay follows at once.
            "overlayPrefs" -> result.success(OverlayPrefs.read(appContext).toMap())
            "setOverlayPrefs" -> result.success(OverlayPrefs.write(appContext, call.arguments as? Map<*, *>).toMap())
            else -> result.notImplemented()
        }
        if (call.method == "setBackgroundMode" || call.method == "adbConnect" || call.method == "requestShizukuPermission") {
            control.emitStatus()
        }
    }

    /**
     * `finishTask {taskId, sessionId?, host?, reopen}`: the linked turn ended. Closes the
     * overlay; with [reopen] and the app in the background, brings it forward on that conversation
     * and waits up to 3 seconds to see its real host resumed. Answers also include `notified`
     * and `current`: closed remains a fact if a successor retires delayed return permission.
     * `busy` — not closed while a phone call runs (not proof of ownership); `opened` — the app
     * is on screen now; `launched` — the start adapter returned true, not proof of visibility.
     */
    private fun finishTask(call: MethodCall, result: MethodChannel.Result) {
        val pluginOwner = promptOwner
        val rawTask = call.argument<Any>("taskId")
        val taskId = when (rawTask) { is Int -> rawTask.toLong(); is Long -> rawTask; else -> null }?.takeIf { it > 0 }
        val session = call.argument<String>("sessionId")?.takeIf { it.isNotEmpty() }
        val host = call.argument<String>("host")
        val reopen = call.argument<Boolean>("reopen") == true
        io.execute {
            if (!attached || promptOwner !== pluginOwner) {
                main.post { result.success(mapOf("closed" to false, "busy" to false, "opened" to false,
                    "launched" to false, "notified" to false, "current" to false, "reason" to "stale")) }
                return@execute
            }
            val scope = taskId?.let { runCatching { control.finishTaskScope(it) }.getOrNull() }
            val closed = scope != null
            val busy = !closed && control.tasks.callsInFlight > 0
            val waitingOwner = scope ?: taskId?.let { control.tasks.activeOwner(it) }
            main.post {
                PhoneTaskReturn(
                    current = { attached && promptOwner === pluginOwner && waitingOwner != null && control.tasks.isCurrent(waitingOwner) },
                    visible = control.prompts::appResumed,
                    launch = { control.reopen(session, host) },
                    notify = { taskId != null && control.notificationGate.notifyFinished(taskId, session, host) },
                    schedule = { delay, block -> main.postDelayed(block, delay) },
                    clock = SystemClock::elapsedRealtime,
                ).start(closed, busy, reopen, result::success)
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink?.let { control.removeSink(it) }
        val s: (Map<String, Any?>) -> Unit = { events.success(it) }
        sink = s
        control.addSink(s)
    }

    override fun onCancel(arguments: Any?) {
        sink?.let { control.removeSink(it) }
        sink = null
    }

}
