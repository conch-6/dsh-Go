package io.github.ccch1mneyyy.dsh_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.files.FilesPlugin
import io.github.ccch1mneyyy.dsh_app.launch.LaunchScreen
import io.github.ccch1mneyyy.dsh_app.launch.LaunchThemeSync
import io.github.ccch1mneyyy.dsh_app.links.LinksPlugin
import io.github.ccch1mneyyy.dsh_app.notify.NotifyPlugin
import io.github.ccch1mneyyy.dsh_app.phone.PhonePlugin
import io.github.ccch1mneyyy.dsh_app.runtime.LaunchStart
import io.github.ccch1mneyyy.dsh_app.runtime.RuntimePlugin
import io.github.ccch1mneyyy.dsh_app.share.SharePlugin
import io.github.ccch1mneyyy.dsh_app.shortcuts.ShortcutsPlugin
import io.github.ccch1mneyyy.dsh_app.update.UpdatePlugin
import io.github.ccch1mneyyy.dsh_app.voice.VoicePlugin
import java.lang.ref.WeakReference
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    private var appChannel: MethodChannel? = null

    /**
     * One engine per process, outliving this activity: swiping the app away from recents keeps
     * Dart running, and with it the event subscriptions behind turn-finished / needs-you
     * notifications. Plugins are registered once, with the engine.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        return FlutterEngine(applicationContext).also { engine ->
            engine.plugins.add(RuntimePlugin())
            engine.plugins.add(PhonePlugin())
            engine.plugins.add(NotifyPlugin())
            engine.plugins.add(FilesPlugin())
            engine.plugins.add(LinksPlugin())
            engine.plugins.add(UpdatePlugin())
            engine.plugins.add(VoicePlugin())
            engine.plugins.add(SharePlugin())
            engine.plugins.add(ShortcutsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.diagnostics.DiagnosticsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.media.MediaPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.icons.LauncherIconPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.theme.DynamicColorPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.performance.PerformancePlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.pet.PetOverlayPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.islands.IslandsPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.nativemedia.NativeMediaPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.nativefiles.NativeFilesPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.web.WebFilesPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.launch.LaunchPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.launch.LaunchClipPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.icons.PictureShortcutPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.usage.UsagePlugin())
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            cache.put(ENGINE_ID, engine)
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    /**
     * This activity's own <meta-data> (normal theme, Flutter deep linking off), whichever launcher
     * alias opened it: Flutter reads it for getComponentName(), which is the alias — that has
     * none of it, and is disabled once the user picks another 桌面图标 (icons/).
     */
    override fun getMetaData(): Bundle? =
        packageManager.getActivityInfo(ComponentName(this, MainActivity::class.java), PackageManager.GET_META_DATA).metaData

    override fun onCreate(savedInstanceState: Bundle?) {
        // 「打开 App 时自动启动」: DSH boots while Flutter starts, not after its first frame.
        LaunchStart.onActivityCreate(this)
        // 启动画面: the first activity of a cold start hands the system's launch window to Dart's.
        LaunchScreen.onActivityCreate(this, coldDart = FlutterEngineCache.getInstance().get(ENGINE_ID) == null)
        // Recreated, or reopened from recents: the launch intent is an old notification tap or
        // link that was handled back then. Don't let the plugins route it again.
        if (savedInstanceState != null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) {
            intent.action = Intent.ACTION_MAIN
            intent.replaceExtras(Bundle())
        }
        super.onCreate(savedInstanceState)
        // Fully transparent system bars, no OEM scrim behind the gesture handle.
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) window.setDecorFitsSystemWindows(false)
        current = WeakReference(this)
        // After LaunchScreen read what this launch's splash showed: the next ones show the icon
        // (and launch screen) chosen now (Android 13+).
        LaunchThemeSync.sync(this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Light / dark: a custom launch screen's plain splash colour (the page's) may change with it.
        LaunchThemeSync.sync(this)
    }

    override fun onResume() {
        super.onResume()
        inForeground = true
        preferFastestDisplayMode()
    }

    /**
     * Asks for the screen's fastest mode at its current resolution. Apps that don't ask stay at
     * 60 or 90 Hz on some 120 Hz phones (OriginOS, HyperOS, ColorOS). The user's refresh-rate
     * setting and power saving still cap it. On resume: the resolution may have changed in
     * Settings meanwhile (density changes don't recreate this activity).
     */
    private fun preferFastestDisplayMode() {
        @Suppress("DEPRECATION")
        val display = windowManager.defaultDisplay
        val now = display.mode
        val fastest = display.supportedModes
            .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        if (window.attributes.preferredDisplayModeId == fastest.modeId) return
        window.attributes = window.attributes.apply { preferredDisplayModeId = fastest.modeId }
    }

    override fun onPause() {
        inForeground = false
        super.onPause()
    }

    /** Per activity: the handler acts on this activity, so it goes with it (see [cleanUpFlutterEngine]). */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/app")
        appChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getTimeZoneId" -> result.success(TimeZone.getDefault().id)
                // A browser sign-in finished (a Custom Tab on top of this task): clearing down
                // to this activity closes the tab and shows the app again.
                "bringToFront" -> {
                    startActivity(
                        Intent(this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        appChannel?.setMethodCallHandler(null)
        appChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // Back on the home screen sends the app to the background instead of finishing the activity
    // (Android 12's default for launcher roots): coming back finds it as it was.
    override fun popSystemNavigator(): Boolean = moveTaskToBack(true)

    companion object {
        private const val ENGINE_ID = "dsh-main"

        /** The app is on screen (resumed). */
        @Volatile var inForeground = false
            private set

        /** The activity now, for what needs one later (the splash theme of the next launches). */
        @Volatile var current: WeakReference<MainActivity>? = null
            private set
    }
}
