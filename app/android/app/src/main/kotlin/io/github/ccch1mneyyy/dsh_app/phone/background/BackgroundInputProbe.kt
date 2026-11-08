package io.github.ccch1mneyyy.dsh_app.phone.background

import android.app.Presentation
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager

/** Inert touch receiver on the gate's disposable display; never opens a user app. */
internal class BackgroundInputProbe(private val context: Context, private val display: Display) : AutoCloseable {
    private val ui = Handler(Looper.getMainLooper())
    private val probe = InputProbe(display.displayId, SystemClock::uptimeMillis)
    var failureDetail: String? = null
        private set
    private var presentation: Presentation? = null // Main looper only.
    private val cleanup = ProbeCleanup { presentation?.dismiss(); presentation = null }

    fun verify(send: (InputProbe.Target, Long) -> Unit) {
        try {
            verifyInput(send)
        } catch (e: Exception) {
            failureDetail = probe.observation(e).encode()
            throw e // Keep SecurityException/InterruptedException and their existing failure codes.
        }
    }

    private fun verifyInput(send: (InputProbe.Target, Long) -> Unit) {
        if (Looper.myLooper() == ui.looper || display.displayId <= Display.DEFAULT_DISPLAY || !display.isValid)
            throw probe.failure("inputWindowNotReady")
        probe.entered(InputProbeDiagnostics.Stage.UI_DISPATCH)
        if (!ui.post {
            if (cleanup.isSealed) return@post
            try {
                probe.entered(InputProbeDiagnostics.Stage.PRESENTATION_CREATE)
                val dialog = Presentation(context, display, android.R.style.Theme_Material_Light_NoActionBar)
                presentation = dialog
                probe.entered(InputProbeDiagnostics.Stage.PRESENTATION_CONFIGURE)
                dialog.setCancelable(false)
                val window = checkNotNull(dialog.window)
                // Keep Presentation's window-context type; changing it breaks Android 12+ tokens.
                window.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED)
                window.setWindowAnimations(0)
                val targetDisplay = display
                val view = object : View(dialog.context) {
                    private var frameRequested = false

                    override fun onDraw(canvas: Canvas) { canvas.drawColor(Color.BLACK) }

                    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
                        super.onSizeChanged(w, h, oldw, oldh)
                        if (frameRequested || w < 4 || h < 4) return
                        frameRequested = true
                        probe.entered(InputProbeDiagnostics.Stage.FRAME_COMMIT_WAIT)
                        viewTreeObserver.registerFrameCommitCallback {
                            ui.post {
                                if (!cleanup.isSealed && isAttachedToWindow && targetDisplay.isValid &&
                                    this.display?.displayId == targetDisplay.displayId) {
                                    probe.entered(InputProbeDiagnostics.Stage.TARGET_VALIDATE)
                                    val location = IntArray(2)
                                    getLocationOnScreen(location)
                                    probe.ready(InputProbe.Target(targetDisplay.displayId,
                                        location[0] + width / 2, location[1] + height / 2))
                                }
                            }
                        }
                    }

                    override fun onTouchEvent(event: MotionEvent): Boolean {
                        if (!cleanup.isSealed) probe.accept(this.display?.displayId ?: Display.INVALID_DISPLAY,
                            event.downTime, event.actionMasked, event.rawX, event.rawY)
                        return true
                    }
                }
                dialog.setContentView(view)
                probe.entered(InputProbeDiagnostics.Stage.PRESENTATION_SHOW)
                dialog.show()
                probe.entered(InputProbeDiagnostics.Stage.VIEW_LAYOUT_WAIT)
                window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
            } catch (e: Exception) {
                probe.fail(e)
            }
        }) throw probe.failure("inputWindowNotReady")
        probe.verify(now = SystemClock::uptimeMillis, send = { target, time ->
            if (cleanup.isSealed || !display.isValid) throw probe.failure("inputWindowNotReady")
            send(target, time)
        })
    }

    override fun close() {
        probe.entered(InputProbeDiagnostics.Stage.CLEANUP)
        // A queued creation sees the sealed gate; an in-flight creation precedes this job.
        // Timeout is not a cleanup acknowledgement; strict owners retain this probe for release.
        var interrupted = Thread.interrupted()
        try {
            cleanup.close(onUiThread = Looper.myLooper() == ui.looper, post = { ui.post(it) })
        } catch (e: InterruptedException) {
            interrupted = true
            val failure = probe.failure("inputProbeCleanupFailed", e)
            failureDetail = failure.observation?.encode()
            throw failure
        } catch (e: Exception) {
            val failure = probe.failure("inputProbeCleanupFailed", e)
            failureDetail = failure.observation?.encode()
            throw failure
        } finally {
            if (interrupted) Thread.currentThread().interrupt()
        }
    }
}
