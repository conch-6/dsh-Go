package io.github.ccch1mneyyy.dsh_app.web

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Process
import android.webkit.MimeTypeMap
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import io.github.ccch1mneyyy.dsh_app.MainActivity

/** A foreground web upload: system-selected content URIs, no persistent grant or cache copy. */
class WebFilesPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private data class Pending(
        val owner: String, val view: WebView, val url: String,
        val multiple: Boolean, val result: MethodChannel.Result,
    )
    private var engine: FlutterPlugin.FlutterPluginBinding? = null
    private var activity: ActivityPluginBinding? = null
    private var channel: MethodChannel? = null
    private var pending: Pending? = null
    // Cancelling the owner does not dismiss the system picker. Do not let a
    // late result satisfy a new request with the same Activity request code.
    private var waiting = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engine = binding
        channel = MethodChannel(binding.binaryMessenger, "dsh/web-files").also { it.setMethodCallHandler(this) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancel()
        channel?.setMethodCallHandler(null)
        channel = null
        engine = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        cancel()
        activity?.removeActivityResultListener(this)
        activity = null
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        waiting = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(call, result)
            "cancel" -> {
                if (call.argument<String>("owner") == pending?.owner) cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(call: MethodCall, result: MethodChannel.Result) {
        val binding = engine
        val activity = activity?.activity
        val id = (call.argument<Any>("webViewId") as? Number)?.toLong()
        val view = if (binding != null && id != null)
            runCatching { WebViewFlutterAndroidExternalApi.getWebView(binding, id) }.getOrNull() else null
        val owner = call.argument<String>("owner")
        val url = call.argument<String>("url")
        if (waiting || pending != null || activity == null || !MainActivity.inForeground ||
            view == null || !view.isShown || owner.isNullOrEmpty() || url.isNullOrEmpty() || view.url != url) {
            result.success(emptyList<String>()); return
        }
        val types = WebFilePolicy.acceptTypes(call.argument<List<String>>("acceptTypes") ?: emptyList()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(it)
        }
        val multiple = call.argument<Boolean>("multiple") == true
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = types.singleOrNull() ?: "*/*"
            if (types.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pending = Pending(owner, view, url, multiple, result)
        waiting = true
        try {
            activity.startActivityForResult(intent, REQUEST)
        } catch (_: Exception) {
            waiting = false
            cancel()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        waiting = false
        val request = pending ?: return true
        pending = null
        val context = engine?.applicationContext
        if (resultCode != Activity.RESULT_OK || data == null || context == null ||
            request.view.url != request.url || !request.view.isAttachedToWindow) {
            request.result.success(emptyList<String>()); return true
        }
        val uris = data.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } }
            ?: listOfNotNull(data.data)
        val allowed = uris.isNotEmpty() && (request.multiple || uris.size == 1) && uris.all { uri ->
            uri != null && WebFilePolicy.isExternalContent(uri.toString(), context.packageName) &&
                context.packageManager.resolveContentProvider(uri.authority ?: "", 0)?.applicationInfo?.uid != Process.myUid() &&
                context.checkUriPermission(uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) ==
                    PackageManager.PERMISSION_GRANTED
        }
        request.result.success(if (allowed) uris.map { it.toString() }.distinct() else emptyList<String>())
        return true
    }

    private fun cancel() {
        val request = pending
        pending = null
        request?.result?.success(emptyList<String>())
    }

    companion object { private const val REQUEST = 0x6D57 }
}
