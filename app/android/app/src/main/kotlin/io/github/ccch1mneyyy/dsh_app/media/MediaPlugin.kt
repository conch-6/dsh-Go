package io.github.ccch1mneyyy.dsh_app.media

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.ccch1mneyyy.dsh_app.files.FilesPlugin
import java.io.File
import java.io.IOException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import kotlin.concurrent.thread

/**
 * Images from chats into the phone's gallery (「保存到相册」): MethodChannel `dsh/media`.
 *
 * - `saveImage {bytes, name, mime}` → where it landed, as the gallery shows it
 *   (`Pictures/DSH Go/x.png`). Android 10+: MediaStore Images under `Pictures/DSH Go`,
 *   which needs no permission for the app's own pictures. Android 8–9: the public
 *   Pictures directory plus a media scan, after asking for the storage permission
 *   (this app targets SDK 28, so it is a runtime grant). On 10+ the permission is
 *   asked for only if MediaStore turns the app away; asked once per save.
 * - `openSettings` → the app's system settings page (to grant storage after a
 *   "don't ask again").
 *
 * Errors: `invalid` (no bytes, not an image type), `permission` (storage write
 * refused), `failed`.
 */
class MediaPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var methods: MethodChannel
    private lateinit var context: Context
    private var activity: ActivityPluginBinding? = null
    private var pendingSave: (() -> Unit)? = null
    private var pendingDenied: (() -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    /** A rotation: the permission answer still arrives, at the recreated activity. */
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        // The engine outlives the activity: a request left open would never be answered.
        val denied = pendingDenied
        pendingSave = null
        pendingDenied = null
        denied?.invoke()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveImage" -> saveImage(call, result)
            "openSettings" -> result.success(openSettings())
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Save

    private fun saveImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null || bytes.isEmpty()) return result.error("invalid", "no image bytes", null)
        val mime = call.argument<String>("mime") ?: ""
        if (mime !in IMAGE_TYPES) return result.error("invalid", "not a gallery image type: $mime", null)
        val given = call.argument<String>("name")?.trim().orEmpty()
        val name = if (given.isEmpty()) "DSH_${System.currentTimeMillis()}.${IMAGE_TYPES.getValue(mime)}" else FilesPlugin.safeName(given)
        if (pendingSave != null) return result.error("failed", "a save is waiting for the storage permission", null)
        saveOrAsk(bytes, name, mime, result, asked = false)
    }

    /**
     * Saves on a worker thread. Android 8–9 need the storage permission for the
     * public Pictures directory, so it is asked for first; on 10+ it is asked for
     * only if MediaStore refuses this (targetSdk 28) app.
     */
    private fun saveOrAsk(bytes: ByteArray, name: String, mime: String, result: MethodChannel.Result, asked: Boolean) {
        val retry = { saveOrAsk(bytes, name, mime, result, asked = true) }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && !canWriteShared()) {
            return if (asked) result.error("permission", "storage permission denied", null) else ask(result, retry)
        }
        thread(name = "dsh-media", isDaemon = true) {
            val outcome = runCatching { saveNow(bytes, name, mime) }
            main.post {
                val error = outcome.exceptionOrNull()
                val refused = error is SecurityException || (error is MediaError && error.code == "permission")
                when {
                    error == null -> result.success(outcome.getOrNull())
                    refused && !asked && activity != null -> ask(result, retry)
                    else -> fail(result, error)
                }
            }
        }
    }

    private fun ask(result: MethodChannel.Result, then: () -> Unit) {
        val host = activity?.activity ?: return result.error("permission", "no activity to ask for permission", null)
        pendingSave = then
        pendingDenied = { result.error("permission", "storage permission denied", null) }
        host.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), STORAGE_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != STORAGE_REQUEST) return false
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        val next = if (granted) pendingSave else pendingDenied
        pendingSave = null
        pendingDenied = null
        next?.invoke()
        return true
    }

    private fun saveNow(bytes: ByteArray, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                return saveToMediaStore(bytes, name, mime)
            } catch (e: SecurityException) {
                if (!canWriteShared()) throw MediaError("permission", e.message)
            } catch (e: IOException) {
                if (!canWriteShared()) throw e
            }
        }
        if (!canWriteShared()) throw MediaError("permission", "storage permission denied")
        val pictures = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
        val dir = File(pictures, ALBUM).apply { mkdirs() }
        if (!dir.isDirectory) throw IOException("cannot create $dir")
        val target = writeUnique(dir, name, bytes)
        MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), arrayOf(mime), null)
        return "${Environment.DIRECTORY_PICTURES}/$ALBUM/${target.name}"
    }

    private fun saveToMediaStore(bytes: ByteArray, name: String, mime: String): String {
        val resolver = context.contentResolver
        val now = System.currentTimeMillis()
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$ALBUM")
            // Galleries sort by when a picture was taken: put it with today's.
            put(MediaStore.Images.Media.DATE_TAKEN, now)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri: Uri = resolver.insert(collection, values) ?: throw IOException("MediaStore refused the image")
        try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IOException("cannot write $uri")
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        // MediaStore renames on collision ("chart (1).png"): report the name it kept.
        val shown = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: name
        return "${Environment.DIRECTORY_PICTURES}/$ALBUM/$shown"
    }

    private fun canWriteShared(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) return true
        val granted = context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        if (!granted) return false
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || Environment.isExternalStorageLegacy()
    }

    // ---------------------------------------------------------------------------------------------

    private fun openSettings(): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
        val host = activity?.activity
        return runCatching {
            if (host != null) host.startActivity(intent)
            else context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.isSuccess
    }

    private fun fail(result: MethodChannel.Result, e: Throwable) = when (e) {
        is MediaError -> result.error(e.code, e.message, null)
        is SecurityException -> result.error("permission", e.message, null)
        else -> result.error("failed", e.message ?: e.javaClass.simpleName, null)
    }

    private class MediaError(val code: String, message: String?) : Exception(message)

    companion object {
        const val CHANNEL = "dsh/media"

        /** The gallery album: `Pictures/DSH Go`, the app's name as galleries show it (downloads go to
         *  `Download/DSH-Go`, a path the agent types). */
        private const val ALBUM = "DSH Go"
        private const val STORAGE_REQUEST = 0x5d7

        /** Own the chosen name before writing; another save must choose its own target. */
        internal fun writeUnique(dir: File, name: String, bytes: ByteArray): File {
            while (true) {
                val target = FilesPlugin.unique(dir, name)
                val output = try {
                    Files.newOutputStream(target.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
                } catch (_: FileAlreadyExistsException) {
                    continue
                }
                try {
                    output.use { it.write(bytes) }
                    return target
                } catch (error: Throwable) {
                    try {
                        Files.deleteIfExists(target.toPath())
                    } catch (cleanup: Throwable) {
                        error.addSuppressed(cleanup)
                    }
                    throw error
                }
            }
        }

        /** What a gallery takes, by MIME type → file extension. */
        private val IMAGE_TYPES = mapOf(
            "image/png" to "png",
            "image/jpeg" to "jpg",
            "image/gif" to "gif",
            "image/webp" to "webp",
        )
    }
}
