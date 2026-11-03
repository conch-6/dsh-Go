package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.os.Bundle
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The pet itself, in a window of one of [PetFrames]' frames (the wide hit box at rest, grown
 * around the lifted pose while held, around the current animation's cell when it reaches past
 * rest): one cell of the current animation placed at its box on the canvas, whole, a whole number
 * of physical pixels per art pixel and unfiltered for 1× pixel art, smoothly scaled for hi-res
 * packs. Software drawn (the window asks for no hardware acceleration): a small view redrawn only
 * when the frame changes.
 *
 * Touch, on the body ([PetFrames.hit]): drag moves the window, a tap opens the conversation, a
 * long press opens the menu. A touch that starts elsewhere in a grown window does nothing.
 */
@SuppressLint("ViewConstructor")
internal class PetView(context: Context, private val listener: Listener) : View(context) {

    interface Listener {
        fun onDragStart()
        fun onDrag(dx: Int, dy: Int)
        fun onDragEnd(velocityX: Float)
        fun onTap(leftHalf: Boolean)
        fun onLongPress()

        /** The system hid or showed the window (e.g. another app's setHideOverlayWindows). */
        fun onShownChanged(shown: Boolean)
    }

    private val paint = Paint().apply { isFilterBitmap = false; isAntiAlias = false; isDither = false }
    private val src = Rect()
    private val dst = RectF()
    private var sprites: PetSprites.Loaded? = null
    private var anim: PetAnimation? = null
    private var cell = -1

    /** The window's frame now, around the rest frame's origin (see [PetFrames]). */
    var frame = FramePx(0, 0, 0, 0)
        private set

    /** The animation on screen (null before the first sheet arrives). */
    val shown: PetAnimation? get() = anim

    fun setSprites(loaded: PetSprites.Loaded?) {
        sprites = loaded
        paint.isFilterBitmap = loaded?.pack?.crisp == false
        anim = null
        cell = -1
        frame = loaded?.frames?.rest ?: FramePx(0, 0, 0, 0)
        requestLayout()
        invalidate()
    }

    /**
     * Draws into [next] from now on (the window is resized to it in the same main-thread turn, so
     * the pet stays put on screen). False when it already was.
     */
    fun setFrame(next: FramePx): Boolean {
        if (next == frame) return false
        frame = next
        requestLayout()
        invalidate()
        return true
    }

    /**
     * Shows [frameIndex] of [animation] if its sheet is decoded (else keeps the last picture and
     * returns false). Redraws only when the cell actually changes.
     */
    fun show(animation: PetAnimation, frameIndex: Int): Boolean {
        val s = sprites ?: return false
        if (s.sheet(animation) == null) return false
        val c = animation.frames.getOrNull(frameIndex)?.cell ?: return false
        if (animation === anim && c == cell) return true
        anim = animation
        cell = c
        invalidate()
        return true
    }

    /** The window's size at rest. */
    val pixelWidth: Int get() = sprites?.frames?.rest?.width ?: 0
    val pixelHeight: Int get() = sprites?.frames?.rest?.height ?: 0

    /** Every frame the window may take while docked ([PetFrames.reach]). */
    val reach: FramePx get() = sprites?.frames?.reach ?: frame

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(frame.width, frame.height)
    }

    override fun onDraw(canvas: Canvas) {
        val s = sprites ?: return
        val a = anim ?: return
        if (cell < 0) return
        val sheet = s.sheet(a) ?: return
        val r = sheet.perLogical
        val cw = (a.box.w * r).toInt()
        val ch = (a.box.h * r).toInt()
        val col = cell % a.cols
        val row = cell / a.cols
        src.set(col * cw, row * ch, (col + 1) * cw, (row + 1) * ch)
        if (src.right > sheet.bitmap.width || src.bottom > sheet.bitmap.height) return
        // Placed on whole physical pixels, from the rest origin whatever the frame (the pet doesn't
        // move when the window grows); the size is whole too for 1× pixel art (k is an integer).
        val at = s.frames.cell(a)
        dst.set(
            (at.left - frame.left).toFloat(), (at.top - frame.top).toFloat(),
            (at.right - frame.left).toFloat(), (at.bottom - frame.top).toFloat(),
        )
        canvas.drawBitmap(sheet.bitmap, src, dst, paint)
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        listener.onShownChanged(visibility == VISIBLE)
    }

    // ---- touch ---------------------------------------------------------------------------------

    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val longPressMs = ViewConfiguration.getLongPressTimeout().toLong()
    private var downX = 0f
    private var downY = 0f
    private var dragging = false
    private var longPressed = false
    private var tracker: VelocityTracker? = null
    private val longPress = Runnable {
        if (!dragging) {
            longPressed = true
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            listener.onLongPress()
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // Off the body (a thought cloud, the air over a jump): not the pet's, and the rest
                // of the gesture isn't either.
                if (!onBody(event.x, event.y)) return false
                downX = event.rawX
                downY = event.rawY
                dragging = false
                longPressed = false
                tracker?.recycle()
                tracker = VelocityTracker.obtain().also { it.addMovement(event) }
                postDelayed(longPress, longPressMs)
            }
            MotionEvent.ACTION_MOVE -> {
                tracker?.addMovement(event)
                val dx = event.rawX - downX
                val dy = event.rawY - downY
                if (!dragging && !longPressed && (abs(dx) > slop || abs(dy) > slop)) {
                    dragging = true
                    removeCallbacks(longPress)
                    listener.onDragStart()
                }
                if (dragging) listener.onDrag(dx.roundToInt(), dy.roundToInt())
            }
            MotionEvent.ACTION_UP -> {
                removeCallbacks(longPress)
                tracker?.addMovement(event)
                when {
                    dragging -> listener.onDragEnd(velocity())
                    // Left and right halves split at the body's centre line (anchor.x), not the window's.
                    !longPressed -> listener.onTap(
                        event.x + frame.left < (sprites?.let { (it.pack.anchorX - it.window.x) * it.screenScale } ?: (width / 2f)),
                    )
                }
                reset()
            }
            MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(longPress)
                if (dragging) listener.onDragEnd(0f)
                reset()
            }
        }
        return true
    }

    /** Whether ([x], [y]) in the view is on the shown animation's body, or anywhere before any is shown. */
    private fun onBody(x: Float, y: Float): Boolean {
        val f = sprites?.frames ?: return true
        return f.hit(anim).contains(x + frame.left, y + frame.top)
    }

    private fun velocity(): Float {
        val t = tracker ?: return 0f
        t.computeCurrentVelocity(1000)
        return t.xVelocity
    }

    private fun reset() {
        dragging = false
        tracker?.recycle()
        tracker = null
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(longPress)
        reset()
        super.onDetachedFromWindow()
    }

    // ---- accessibility: a button that opens the conversation, long-press for the menu ----------

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = "android.widget.Button"
        info.isClickable = true
        info.isLongClickable = true
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, AppStrings.get(context, R.string.pet_open_chat)))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_LONG_CLICK, AppStrings.get(context, R.string.pet_more)))
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean = when (action) {
        AccessibilityNodeInfo.ACTION_CLICK -> { listener.onTap(false); true }
        AccessibilityNodeInfo.ACTION_LONG_CLICK -> { listener.onLongPress(); true }
        else -> super.performAccessibilityAction(action, arguments)
    }
}
