package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.phone.PromptInputPolicy
import io.github.ccch1mneyyy.dsh_app.phone.a11y.InjectGuard
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Color
import android.view.HapticFeedbackConstants
import android.widget.FrameLayout
import android.widget.ScrollView
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.roundToInt
import kotlin.math.cos
import kotlin.math.sin
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.SystemClock
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.LinearLayout
import android.widget.TextView

/** The app's 雾蓝 surfaces and ink (app/lib/ui/theme/palette.dart), as phone/a11y/ControlOverlay.kt uses them. */
internal class OverlayPalette(
    val fill: Int, val stroke: Int, val ink: Int, val muted: Int, val pressed: Int,
    val accent: Int, val onAccent: Int, val tonal: Int, val onTonal: Int, val danger: Int,
) {
    companion object {
        private val light = OverlayPalette(
            fill = 0xFFFBFCFF.toInt(), stroke = 0xFFDCE0E8.toInt(), ink = 0xFF1E232E.toInt(),
            muted = 0xFF646974.toInt(), pressed = 0xFFE7EBF4.toInt(),
            accent = 0xFF4B67B4.toInt(), onAccent = 0xFFFFFFFF.toInt(), tonal = 0xFFDEE8FF.toInt(), onTonal = 0xFF213262.toInt(),
            danger = 0xFFB3261E.toInt(),
        )
        private val dark = OverlayPalette(
            fill = 0xFF232730.toInt(), stroke = 0xFF343841.toInt(), ink = 0xFFE6E9F0.toInt(),
            muted = 0xFF9A9EA9.toInt(), pressed = 0xFF2D323C.toInt(),
            accent = 0xFF97B1F0.toInt(), onAccent = 0xFF121C34.toInt(), tonal = 0xFF2E3C5F.toInt(), onTonal = 0xFFD8E1F6.toInt(),
            danger = 0xFFFFB4AB.toInt(),
        )

        fun of(context: Context): OverlayPalette =
            if (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES) dark else light
    }
}

internal fun Context.dp(v: Float): Int =
    TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

/**
 * Rounded card with a small tail pointing at the pet: down when the bubble is above it, up when
 * below, sideways when beside it ([Tail]); [tailAt] is where along that edge.
 */
internal class BubbleBackground(
    private val palette: OverlayPalette,
    private val radius: Float,
    private val tailW: Float,
    val tailH: Float,
    private val strokeW: Float,
) : Drawable() {
    var tailAt = 0f
    var tail = Tail.DOWN
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = palette.fill; style = Paint.Style.FILL }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = palette.stroke; style = Paint.Style.STROKE; strokeWidth = strokeW }
    private val path = Path()
    private val box = RectF()

    override fun draw(canvas: Canvas) {
        val b = bounds
        val inset = strokeW / 2
        box.set(
            b.left + inset + (if (tail == Tail.LEFT) tailH else 0f),
            b.top + inset + (if (tail == Tail.UP) tailH else 0f),
            b.right - inset - (if (tail == Tail.RIGHT) tailH else 0f),
            b.bottom - inset - (if (tail == Tail.DOWN) tailH else 0f),
        )
        path.reset()
        path.addRoundRect(box, radius, radius, Path.Direction.CW)
        val tail = Path()
        when (this.tail) {
            Tail.DOWN, Tail.UP -> {
                val tx = tailAt.coerceIn(box.left + radius, maxOf(box.left + radius, box.right - radius))
                val edge = if (this.tail == Tail.DOWN) box.bottom - inset else box.top + inset
                val tip = if (this.tail == Tail.DOWN) box.bottom + tailH else box.top - tailH
                tail.moveTo(tx - tailW / 2, edge)
                tail.lineTo(tx, tip)
                tail.lineTo(tx + tailW / 2, edge)
            }
            Tail.LEFT, Tail.RIGHT -> {
                // A short card: the tail may start on the corners' curve, the union covers it.
                val ty = tailAt.coerceIn(box.top + tailW / 2, maxOf(box.top + tailW / 2, box.bottom - tailW / 2))
                val edge = if (this.tail == Tail.RIGHT) box.right - inset else box.left + inset
                val tip = if (this.tail == Tail.RIGHT) box.right + tailH else box.left - tailH
                tail.moveTo(edge, ty - tailW / 2)
                tail.lineTo(tip, ty)
                tail.lineTo(edge, ty + tailW / 2)
            }
        }
        tail.close()
        path.op(tail, Path.Op.UNION)
        canvas.drawPath(path, fill)
        canvas.drawPath(path, stroke)
    }

    override fun setAlpha(alpha: Int) {
        fill.alpha = alpha
        stroke.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        fill.colorFilter = colorFilter
        stroke.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

/**
 * The bubble: one line, 「标题 · 做完了」; under it 问一句's reply (its first two lines), or a request
 * with its answers (docs/design/pets.md §2.7). Nothing else from a conversation ever shows here.
 */
@SuppressLint("ViewConstructor")
internal class BubbleView(context: Context, onTap: () -> Unit) : LinearLayout(context) {
    private val palette = OverlayPalette.of(context)
    private val bg = BubbleBackground(
        palette,
        radius = context.dp(14f).toFloat(),
        tailW = context.dp(12f).toFloat(),
        tailH = context.dp(6f).toFloat(),
        strokeW = context.dp(1f).coerceAtLeast(1).toFloat(),
    )
    private val padH = context.dp(14f)
    private val padV = context.dp(8f)
    private val text = TextView(context).apply {
        textSize = 14f
        setTextColor(palette.ink)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    /** The reply's first lines, or what a request asks: under the line. */
    private val detail = TextView(context).apply {
        textSize = 13f
        setTextColor(palette.ink)
        setLineSpacing(0f, 1.15f)
        ellipsize = TextUtils.TruncateAt.END
        visibility = GONE
    }
    private val actions = LinearLayout(context).apply { orientation = VERTICAL; visibility = GONE }
    private var wide = false

    init {
        orientation = VERTICAL
        background = bg
        addView(text, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        addView(detail, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(2f) })
        addView(actions, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(8f) })
        isClickable = true
        setOnClickListener { onTap() }
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE
        setTail(0, Tail.DOWN)
    }

    /** One line fits in 240 dp; a request with its buttons gets a little more. */
    val maxBubbleWidth: Int get() = context.dp(if (wide) 272f else 240f)

    /** How far the tail reaches out of the card. */
    val tailPx: Int get() = bg.tailH.toInt()

    fun bind(b: PetBubble) {
        text.text = b.line
        val more = b.ask?.text ?: b.detail
        detail.text = more
        detail.maxLines = if (b.ask != null) ASK_LINES else DETAIL_LINES
        detail.visibility = if (more == null) GONE else VISIBLE
        wide = b.ask != null
        contentDescription = listOfNotNull(b.line, more).joinToString("\n")
    }

    /** After [measureCard]: the request's text shows whole, nothing cut off at its last line. */
    fun detailWhole(): Boolean {
        val layout = detail.layout ?: return detail.visibility == GONE
        return layout.lineCount <= detail.maxLines && layout.getEllipsisCount(layout.lineCount - 1) == 0
    }

    private val buttons = ArrayList<TextView>()

    /**
     * Puts [list] under the text, each calling [onAction]. Answers (not 「去回答」) are guarded as
     * phone control's prompt is: no touch before [armedAt], none through another window, none injected.
     */
    fun setActions(list: List<BubbleAction>, kind: String?, armedAt: Long, onAction: (BubbleAction) -> Unit) {
        actions.removeAllViews()
        buttons.clear()
        actions.visibility = if (list.isEmpty()) GONE else VISIBLE
        if (list.isEmpty()) return
        val gap = context.dp(8f)
        val pair = list.size == 2 && list.all { it.kind == BubbleAction.Kind.REJECT || it.kind == BubbleAction.Kind.ALLOW }
        val row = if (pair) LinearLayout(context).apply { orientation = HORIZONTAL }.also { actions.addView(it) } else actions
        for ((i, a) in list.withIndex()) {
            val primary = a.kind == BubbleAction.Kind.ALLOW
            val label = when (a.kind) {
                // The notification's own words: one grant, this call only.
                BubbleAction.Kind.ALLOW -> AppStrings.get(context, R.string.notify_allow_once)
                BubbleAction.Kind.REJECT -> AppStrings.get(context, R.string.notify_decline)
                BubbleAction.Kind.CHOOSE -> a.choice.orEmpty()
                BubbleAction.Kind.OPEN -> AppStrings.get(context, if (kind == PetAsk.QUESTION) R.string.pet_go_answer else R.string.pet_go_review)
            }
            val b = (if (a.kind == BubbleAction.Kind.OPEN) TextView(context) else GuardedButton(context, armedAt)).apply {
                text = label
                textSize = 14f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                gravity = Gravity.CENTER
                // Choice labels are consent: wrap them instead of hiding a suffix.
                maxLines = if (a.kind == BubbleAction.Kind.CHOOSE) Int.MAX_VALUE else 1
                ellipsize = if (a.kind == BubbleAction.Kind.CHOOSE) null else TextUtils.TruncateAt.END
                minHeight = context.dp(40f)
                setPadding(context.dp(12f), 0, context.dp(12f), 0)
                setTextColor(if (primary) palette.onAccent else if (a.kind == BubbleAction.Kind.OPEN) palette.onTonal else palette.ink)
                background = GradientDrawable().apply {
                    cornerRadius = context.dp(12f).toFloat()
                    setColor(if (primary) palette.accent else if (a.kind == BubbleAction.Kind.OPEN) palette.tonal else palette.fill)
                    if (!primary && a.kind != BubbleAction.Kind.OPEN) setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
                }
                isClickable = true
                isFocusable = true
                setOnClickListener { onAction(a) }
            }
            buttons += b
            val lp = if (pair) {
                LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply { if (i > 0) marginStart = gap }
            } else {
                LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { if (i > 0) topMargin = gap }
            }
            row.addView(b, lp)
        }
        // Guarded answers read as off until they take touches, as on phone control's prompt.
        val wait = (armedAt - SystemClock.uptimeMillis()).coerceAtLeast(0)
        for (b in buttons) {
            if (b !is GuardedButton || wait == 0L) continue
            b.alpha = 0.5f
            b.animate().alpha(1f).setStartDelay(wait).setDuration(120).start()
        }
    }

    /** An answer is on its way: [busy]'s button says so, none takes another tap. */
    fun setBusy(busy: BubbleAction?) {
        for (b in buttons) {
            b.isEnabled = busy == null
            b.alpha = if (busy == null) 1f else 0.5f
        }
    }

    /** The answer didn't go through: [message] in place of the request, one button to the chat. */
    fun showFailed(message: String, kind: String?, onOpen: () -> Unit) {
        detail.text = message
        detail.visibility = VISIBLE
        setActions(listOf(BubbleAction(BubbleAction.Kind.OPEN)), kind, 0L) { onOpen() }
        contentDescription = listOfNotNull(text.text, message).joinToString("\n")
    }

    /** Points the tail [tail]wards, [at] px along that edge; the window grows by [tailPx] on that side. */
    fun setTail(at: Int, tail: Tail) {
        bg.tailAt = at.toFloat()
        bg.tail = tail
        val t = tailPx
        setPadding(
            padH + (if (tail == Tail.LEFT) t else 0), padV + (if (tail == Tail.UP) t else 0),
            padH + (if (tail == Tail.RIGHT) t else 0), padV + (if (tail == Tail.DOWN) t else 0),
        )
        invalidate()
    }

    /** The card's size, the tail left out, within [maxBubbleWidth]. */
    fun measureCard(): Pair<Int, Int> {
        measure(
            MeasureSpec.makeMeasureSpec(maxBubbleWidth, MeasureSpec.AT_MOST),
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
        )
        return when (bg.tail) {
            Tail.DOWN, Tail.UP -> measuredWidth to measuredHeight - tailPx
            Tail.LEFT, Tail.RIGHT -> measuredWidth - tailPx to measuredHeight
        }
    }

    private companion object {
        /** 问一句's reply: its first two lines. */
        const val DETAIL_LINES = 2

        /** A request: up to four lines, and answered only when it fits them whole. */
        const val ASK_LINES = 4
    }
}

/**
 * A bubble's answer key, as careful as phone control's prompt ([PromptInputPolicy]): no touch before
 * [armedAt] (the bubble may pop up under a finger), none through another app's window, none
 * injected by an accessibility service unless TalkBack is the one reading.
 */
@SuppressLint("ViewConstructor")
internal class GuardedButton(context: Context, private val armedAt: Long) : TextView(context) {
    private val a11y = context.getSystemService(AccessibilityManager::class.java)
    private var rejected = false

    init {
        filterTouchesWhenObscured = true
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            rejected = !PromptInputPolicy.allows(
                SystemClock.uptimeMillis(), armedAt, isEnabled, InjectGuard.active(),
                event.flags and (MotionEvent.FLAG_WINDOW_IS_OBSCURED or 0x2) != 0,
                event.deviceId <= 0, event.flags and FLAG_IS_ACCESSIBILITY_EVENT != 0 || event.getToolType(0) == MotionEvent.TOOL_TYPE_UNKNOWN,
                a11y.isTouchExplorationEnabled,
            )
        }
        if (rejected) {
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) isPressed = false
            return true
        }
        return super.dispatchTouchEvent(event)
    }

    override fun performClick(): Boolean {
        if (!isEnabled || SystemClock.uptimeMillis() < armedAt || InjectGuard.active()) return false
        return super.performClick()
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        if ((action == AccessibilityNodeInfo.ACTION_CLICK || action == AccessibilityNodeInfo.ACTION_LONG_CLICK) &&
            (SystemClock.uptimeMillis() < armedAt || InjectGuard.active() || !a11y.isTouchExplorationEnabled)
        ) {
            return false
        }
        return super.performAccessibilityAction(action, arguments)
    }

    private companion object {
        /** MotionEvent.FLAG_IS_ACCESSIBILITY_EVENT (hidden): dispatched by an accessibility service. */
        const val FLAG_IS_ACCESSIBILITY_EVENT = 0x800
    }
}

/** The 「×」 at the bottom middle while dragging; [setArmed] grows it when the pet is over it. */
internal class DismissTargetView(context: Context) : View(context) {
    private val palette = OverlayPalette.of(context)
    private val disc = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = palette.fill; style = Paint.Style.FILL }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = palette.stroke; style = Paint.Style.STROKE; strokeWidth = context.dp(1f).coerceAtLeast(1).toFloat()
    }
    private val cross = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = palette.ink; style = Paint.Style.STROKE; strokeWidth = context.dp(2f).toFloat(); strokeCap = Paint.Cap.ROUND
    }
    var armed = false
        private set

    fun setArmed(on: Boolean) {
        if (on == armed) return
        armed = on
        animate().scaleX(if (on) 1.2f else 1f).scaleY(if (on) 1.2f else 1f).setDuration(120).start()
    }

    override fun onDraw(canvas: Canvas) {
        val c = width / 2f
        val r = c / 1.2f - ring.strokeWidth
        canvas.drawCircle(c, c, r, disc)
        canvas.drawCircle(c, c, r, ring)
        val a = r * 0.36f
        canvas.drawLine(c - a, c - a, c + a, c + a, cross)
        canvas.drawLine(c - a, c + a, c + a, c - a, cross)
    }
}

/** A native semicircle of accessible buttons; the pet forwards its still-owned pointer stream. */
@SuppressLint("ViewConstructor")
internal class PetMenuView(
    context: Context,
    rows: List<Row>,
    private val onOutside: () -> Unit,
    private val motion: () -> Boolean,
) : FrameLayout(context) {
    class Row(val label: String, val muted: Boolean = false, val item: PetMenuItem? = null, val shortLabel: String = label, val action: () -> Unit)

    private val palette = OverlayPalette.of(context)
    private var rows = rows
    private val buttons = ArrayList<TextView>()
    private val fills = ArrayList<GradientDrawable>()
    private var geometry: PetWheelGeometry? = null
    private var gesture: PetWheelGesture? = null
    private var selection: Int? = null
    private var caption: TextView? = null
    private var amounts = FloatArray(rows.size)
    private var reveal = 0f
    private var lastFrame = 0L
    private var ticking = false
    private var closing = false
    private var closed: (() -> Unit)? = null
    var hosts = false
        private set
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arc = RectF()
    private val visibleRect = Rect()

    init {
        clipChildren = false
        clipToPadding = false
        isClickable = true
        setWillNotDraw(false)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun setRows(next: List<Row>) {
        gesture = null
        selection = null
        hosts = true
        rows = next
        amounts = FloatArray(next.size)
        geometry = null
    }

    fun place(g: PetWheelGeometry) {
        geometry = g
        alpha = if (g.list) reveal else 1f
        caption = null
        removeAllViews()
        buttons.clear()
        fills.clear()
        val list = if (g.list) LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(context.dp(6f), context.dp(6f), context.dp(6f), context.dp(6f))
        } else null
        background = if (g.list) GradientDrawable().apply {
            cornerRadius = context.dp(20f).toFloat()
            setColor(palette.fill)
            setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
        } else null
        if (list != null) addView(ScrollView(context).apply {
            isFillViewport = false
            addView(list)
        }, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        for ((i, row) in rows.withIndex()) {
            val fill = GradientDrawable().apply {
                cornerRadius = context.dp(if (g.list) 14f else 20f).toFloat()
                setColor(palette.fill)
                setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
            }
            val button = TextView(context).apply {
                alpha = if (g.list) 1f else reveal
                text = if (g.list) row.label else row.shortLabel
                contentDescription = row.label
                textSize = if (g.list) 15f else 11f
                gravity = if (g.list) Gravity.CENTER_VERTICAL else Gravity.CENTER
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                setTextColor(if (row.muted) palette.muted else palette.ink)
                maxLines = if (g.list) Int.MAX_VALUE else 2
                setPadding(context.dp(if (g.list) 14f else 3f), context.dp(4f), context.dp(if (g.list) 14f else 3f), context.dp(4f))
                minHeight = context.dp(52f)
                background = fill
                if (!g.list && row.item != null) {
                    val icon = PetWheelIcon(row.item, palette.accent, context.dp(21f))
                    setCompoundDrawables(null, icon, null, null)
                    compoundDrawablePadding = context.dp(3f)
                }
                isClickable = true
                isFocusable = true
                setOnClickListener { if (!closing) row.action() }
            }
            buttons += button
            fills += fill
            if (list != null) list.addView(button, LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            else addView(button, LayoutParams(g.buttonWidth, g.buttonHeight).apply {
                leftMargin = (g.centers[i].first - g.bounds.left - g.buttonWidth / 2f).roundToInt()
                topMargin = (g.centers[i].second - g.bounds.top - g.buttonHeight / 2f).roundToInt()
            })
        }
        if (!g.list) {
            caption = TextView(context).apply {
                text = AppStrings.get(context, R.string.pet_wheel_hint)
                contentDescription = AppStrings.get(context, android.R.string.cancel)
                textSize = 13f
                gravity = Gravity.CENTER
                setTextColor(palette.muted)
                setPadding(context.dp(8f), context.dp(4f), context.dp(8f), context.dp(4f))
                alpha = reveal
                background = GradientDrawable().apply {
                    cornerRadius = context.dp(18f).toFloat()
                    setColor(palette.fill)
                    setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
                }
                setOnClickListener { if (!closing) onOutside() }
            }.also { label ->
                addView(label, LayoutParams(context.dp(128f), context.dp(80f)).apply {
                    leftMargin = (g.centerX - g.bounds.left + g.direction * g.radius * 0.43f - context.dp(64f)).roundToInt()
                    topMargin = (g.centerY - g.bounds.top - context.dp(40f)).roundToInt()
                })
            }
        }
        wake()
    }

    fun beginPointer(x: Float, y: Float) {
        selection = null
        gesture = PetWheelGesture(x, y, context.dp(10f).toFloat())
        wake()
    }

    fun movePointer(x: Float, y: Float) {
        if (closing) return
        val g = geometry ?: return
        val selected = gesture?.move(x, y) {
            if (!g.list) g.hit(x, y, selection) else buttons.indexOfFirst {
                it.getGlobalVisibleRect(visibleRect) && g.hitsVisibleRow(x, y, visibleRect.left, visibleRect.top, visibleRect.right, visibleRect.bottom)
            }.takeIf { it >= 0 }
        }
        if (selection == selected) return
        selection = selected
        caption?.text = selected?.let { rows[it].label } ?: AppStrings.get(context, R.string.pet_wheel_hint)
        caption?.setTextColor(if (selected != null) palette.onTonal else palette.muted)
        if (selected != null) performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        wake()
    }

    fun endPointer(x: Float, y: Float, cancelled: Boolean) {
        val active = gesture ?: return
        movePointer(x, y)
        gesture = null
        val keepList = geometry?.list == true && active.keepListOpen(cancelled)
        val index = active.finish(cancelled)
        // The compact fallback may need native scrolling to reach its last rows. A stationary
        // release hands it a new touch stream; returning after a drag still cancels normally.
        if (keepList && !closing) return
        if (!closing && index != null) rows.getOrNull(index)?.action?.invoke() else onOutside()
    }

    fun close(then: () -> Unit) {
        if (closing) return
        closing = true
        gesture = null
        closed = then
        wake()
    }

    private fun wake() {
        if (!ticking) {
            ticking = true
            lastFrame = SystemClock.uptimeMillis()
            postOnAnimation(tick)
        }
    }

    // One frame loop owns enter, lift and return. Pointer moves only change targets: no layout,
    // Animator allocation or repeated animator cancellation at touch-sampling frequency.
    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            val dt = (now - lastFrame).coerceIn(1, 40)
            lastFrame = now
            val fraction = if (motion()) 1f - exp(-dt / (if (closing) 28f else 42f)) else 1f
            val goal = if (closing) 0f else 1f
            reveal += (goal - reveal) * fraction
            if (abs(goal - reveal) < 0.01f) reveal = goal
            var settling = reveal != goal
            val g = geometry
            if (g?.list == true) alpha = reveal
            caption?.alpha = reveal
            for ((i, b) in buttons.withIndex()) {
                val target = if (selection == i && !closing) 1f else 0f
                amounts[i] += (target - amounts[i]) * fraction
                if (abs(target - amounts[i]) < 0.005f) amounts[i] = target
                settling = settling || amounts[i] != target
                val amount = amounts[i]
                b.scaleX = 1f + 0.1f * amount
                b.scaleY = b.scaleX
                b.alpha = if (g?.list == true) 1f else reveal
                if (g != null && !g.list) {
                    val dx = (g.centers[i].first - g.centerX) / g.radius
                    val dy = (g.centers[i].second - g.centerY) / g.radius
                    val lift = context.dp(9f) * amount - context.dp(14f) * (1f - reveal)
                    b.translationX = dx * lift
                    b.translationY = dy * lift
                }
                fills[i].setColor(blend(palette.fill, palette.tonal, amount))
                fills[i].setStroke(context.dp(1f).coerceAtLeast(1), blend(palette.stroke, palette.accent, amount))
                b.isSelected = selection == i
            }
            invalidate()
            if (closing && reveal == 0f) {
                ticking = false
                val done = closed
                closed = null
                done?.invoke()
            } else if (settling) postOnAnimation(this) else ticking = false
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val g = geometry ?: return
        if (g.list) return
        val cx = g.centerX - g.bounds.left
        val cy = g.centerY - g.bounds.top
        val r = g.radius
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = context.dp(1f).coerceAtLeast(1).toFloat()
        paint.color = palette.stroke
        paint.alpha = (155 * reveal).toInt()
        arc.set(cx - r, cy - r, cx + r, cy + r)
        canvas.drawArc(arc, if (g.side == Side.LEFT) -90f else 90f, 180f, false, paint)
        val inner = context.dp(43f).toFloat()
        arc.set(cx - inner, cy - inner, cx + inner, cy + inner)
        paint.color = palette.accent
        paint.alpha = (110 * reveal).toInt()
        canvas.drawArc(arc, if (g.side == Side.LEFT) -70f else 110f, 140f, false, paint)
        paint.style = Paint.Style.FILL
        paint.alpha = 255
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) {
            onOutside()
            return true
        }
        return if (closing) true else super.dispatchTouchEvent(event)
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(tick)
        ticking = false
        closed = null
        gesture = null
        super.onDetachedFromWindow()
    }

    private fun blend(a: Int, b: Int, t: Float): Int = Color.rgb(
        (Color.red(a) + (Color.red(b) - Color.red(a)) * t).roundToInt(),
        (Color.green(a) + (Color.green(b) - Color.green(a)) * t).roundToInt(),
        (Color.blue(a) + (Color.blue(b) - Color.blue(a)) * t).roundToInt(),
    )
}

/** Small, consistent stroke icons; no font glyphs or third-party UI dependency. */
private class PetWheelIcon(private val item: PetMenuItem, color: Int, size: Int) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color; style = Paint.Style.STROKE; strokeWidth = 1.7f; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val box = RectF()
    init { setBounds(0, 0, size, size) }
    override fun draw(canvas: Canvas) {
        val save = canvas.save()
        canvas.scale(bounds.width() / 24f, bounds.height() / 24f)
        when (item) {
            PetMenuItem.ASK, PetMenuItem.NEW_CHAT -> {
                box.set(3f, 4f, 21f, 18f); canvas.drawRoundRect(box, 4f, 4f, paint)
                canvas.drawLine(7f, 18f, 5f, 21f, paint)
                if (item == PetMenuItem.NEW_CHAT) {
                    canvas.drawLine(8f, 11f, 16f, 11f, paint)
                    canvas.drawLine(12f, 7f, 12f, 15f, paint)
                }
                else { canvas.drawPoint(8f, 11f, paint); canvas.drawPoint(12f, 11f, paint); canvas.drawPoint(16f, 11f, paint) }
            }
            PetMenuItem.SCREENSHOT -> {
                box.set(3f, 6f, 21f, 21f); canvas.drawRoundRect(box, 3f, 3f, paint)
                canvas.drawCircle(12f, 13f, 4f, paint)
                canvas.drawLine(8f, 3f, 16f, 3f, paint)
            }
            PetMenuItem.STOP -> { box.set(5f, 5f, 19f, 19f); canvas.drawRoundRect(box, 3f, 3f, paint) }
            PetMenuItem.SWITCH_HOST -> {
                box.set(3f, 4f, 21f, 10f); canvas.drawRoundRect(box, 2f, 2f, paint)
                box.set(3f, 14f, 21f, 20f); canvas.drawRoundRect(box, 2f, 2f, paint)
                canvas.drawPoint(7f, 7f, paint); canvas.drawPoint(7f, 17f, paint)
            }
            PetMenuItem.SNOOZE -> {
                canvas.drawArc(4f, 3f, 21f, 20f, 35f, 280f, false, paint)
                canvas.drawArc(10f, 0f, 24f, 15f, 100f, 150f, false, paint)
            }
            PetMenuItem.SETTINGS -> {
                canvas.drawCircle(12f, 12f, 6f, paint); canvas.drawCircle(12f, 12f, 2f, paint)
                for (i in 0..7) {
                    val a = i * Math.PI / 4
                    canvas.drawLine(12 + 7 * cos(a).toFloat(), 12 + 7 * sin(a).toFloat(), 12 + 9 * cos(a).toFloat(), 12 + 9 * sin(a).toFloat(), paint)
                }
            }
        }
        canvas.restoreToCount(save)
    }
    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter }
    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}
