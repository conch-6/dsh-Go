package io.github.ccch1mneyyy.dsh_app.links

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.nio.file.Files
import kotlin.concurrent.thread

/**
 * Incoming links and opened files: MethodChannel `dsh/links`.
 *
 * Dart calls `ready` once its handler is set; from then on every arrival is pushed to Dart as a
 * `link` call. (A method call, not an EventChannel: Dart can probe `ready` and treat a missing
 * native side — widget tests, desktop — as "no links", without an error report.)
 *
 * Sources: MainActivity's launch intent (cold start) and every onNewIntent (the activity is
 * singleTop). What is delivered, one map per arrival:
 *
 * - `{uri}`: an ACTION_VIEW link (`dshgo://…`, or `https://…` once App Links are verified).
 * - `{uri: "file://…", name}`: a file opened with the app (ACTION_VIEW `content:` / `file:`),
 *   copied into `cache/links/` first so Dart can read it with dart:io. The copy keeps the
 *   sender's display name as its last path segment. (Files *shared* to the app, `.dshgo`
 *   included, come through share/SharePlugin.kt.)
 * - `{error, name}`: a file that couldn't be read (`too_large` over [MAX_FILE_BYTES],
 *   `unreadable`).
 *
 * Arrivals before `ready` are held and delivered, in order, on `ready`. The launch intent
 * is taken once: it is marked as consumed (survives config-change reattach), and intents that
 * Android replays when the task is reopened from recents are ignored.
 */
class LinksPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private var activity: ActivityPluginBinding? = null
    private var ready = false
    private val pending = ArrayList<Map<String, Any?>>()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        ready = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> {
                ready = true
                val held = ArrayList(pending)
                pending.clear()
                result.success(true)
                for (event in held) methods.invokeMethod("link", event)
            }
            else -> result.notImplemented()
        }
    }

    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
        val launch = binding.activity.intent ?: return
        if (launch.getBooleanExtra(EXTRA_TAKEN, false)) return
        if ((launch.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return
        if (take(launch)) launch.putExtra(EXTRA_TAKEN, true)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeOnNewIntentListener(this)
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean = take(intent)

    /** Delivers what [intent] carries for us; false when it's not a link or a file. */
    private fun take(intent: Intent): Boolean {
        when (intent.action) {
            Intent.ACTION_VIEW -> {
                val data = intent.data ?: return false
                when (data.scheme?.lowercase()) {
                    SCHEME, "https", "http" -> deliver(mapOf("uri" to data.toString()))
                    "content", "file" -> copyThenDeliver(data)
                    else -> return false
                }
                return true
            }
            else -> return false
        }
    }

    // Files

    /** Copies [source] into `cache/links/` off the main thread, then delivers it. */
    private fun copyThenDeliver(source: Uri) {
        thread(name = "dsh-links", isDaemon = true) {
            val event = try {
                copy(source)
            } catch (_: Throwable) {
                mapOf("error" to "unreadable", "name" to null)
            }
            main.post { deliver(event) }
        }
    }

    private fun copy(source: Uri): Map<String, Any?> {
        val resolver = context.contentResolver
        var name: String? = null
        var size = -1L
        if (source.scheme == "content") {
            resolver.query(source, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                if (it.moveToFirst()) {
                    val n = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = it.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0 && !it.isNull(n)) name = it.getString(n)
                    if (s >= 0 && !it.isNull(s)) size = it.getLong(s)
                }
            }
        }
        val shown = safeName(name ?: source.lastPathSegment ?: "shared")
        if (size > MAX_FILE_BYTES) return mapOf("error" to "too_large", "name" to shown)
        val dir = File(context.cacheDir, "links").apply { mkdirs() }
        prune(dir)
        // One folder per arrival so two files with the same name don't collide.
        val slot = Files.createTempDirectory(dir.toPath(), "arrival-").toFile()
        val target = File(slot, shown)
        val input = resolver.openInputStream(source) ?: return mapOf("error" to "unreadable", "name" to shown)
        input.use { stream ->
            target.outputStream().use { out ->
                val buffer = ByteArray(16 * 1024)
                var total = 0L
                while (true) {
                    val read = stream.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > MAX_FILE_BYTES) {
                        out.close()
                        slot.deleteRecursively()
                        return mapOf("error" to "too_large", "name" to shown)
                    }
                    out.write(buffer, 0, read)
                }
            }
        }
        return mapOf("uri" to Uri.fromFile(target).toString(), "name" to shown)
    }

    /** Keeps the last few arrivals. */
    private fun prune(dir: File) {
        val slots = dir.listFiles()?.sortedByDescending { it.lastModified() } ?: return
        for (old in slots.drop(KEEP_FILES)) old.deleteRecursively()
    }

    // Delivery

    private fun deliver(event: Map<String, Any?>) {
        if (ready) methods.invokeMethod("link", event) else pending += event
    }

    companion object {
        const val CHANNEL = "dsh/links"
        const val SCHEME = "dshgo"
        private const val EXTRA_TAKEN = "io.github.ccch1mneyyy.dsh_app.links.TAKEN"
        private const val MAX_FILE_BYTES = 4L * 1024 * 1024
        private const val KEEP_FILES = 6

        /** A file name without path separators or control characters. */
        fun safeName(name: String): String {
            val cleaned = name.substringAfterLast('/').replace(Regex("[\\u0000-\\u001f\\\\:*?\"<>|]"), "_").trim()
            return cleaned.ifEmpty { "shared" }.take(120)
        }
    }
}
