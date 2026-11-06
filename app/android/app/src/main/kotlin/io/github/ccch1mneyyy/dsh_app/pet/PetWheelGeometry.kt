package io.github.ccch1mneyyy.dsh_app.pet

import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlin.math.sin

/** Screen-space geometry shared by drawing and the original pet window's pointer stream. */
internal class PetWheelGeometry private constructor(
    val bounds: ScreenRect,
    val side: Side,
    val centerX: Float,
    val centerY: Float,
    val radius: Float,
    val buttonWidth: Int,
    val buttonHeight: Int,
    val centers: List<Pair<Float, Float>>,
    val density: Float,
    /** A scrollable, full-label click alternative when a readable semicircle cannot fit. */
    val list: Boolean,
) {
    val direction: Float get() = if (side == Side.LEFT) 1f else -1f

    fun hitsVisibleRow(x: Float, y: Float, left: Int, top: Int, right: Int, bottom: Int): Boolean =
        x - bounds.left >= left && x - bounds.left < right && y - bounds.top >= top && y - bounds.top < bottom

    fun hit(x: Float, y: Float, previous: Int? = null): Int? {
        if (list || x < bounds.left || x > bounds.right || y < bounds.top || y > bounds.bottom) return null
        val dx = (x - centerX) * direction
        val dy = y - centerY
        val distance = hypot(dx, dy)
        if (dx < 0 || distance < 52f * density || distance > radius + buttonWidth / 2f + 12f * density) return null
        // The central caption is also the tappable cancel target, not a middle-sector shortcut.
        if (kotlin.math.abs(dx - radius * 0.43f) < 64f * density && kotlin.math.abs(dy) < 40f * density) return null
        val angle = atan2(dy, dx).toDouble()
        val step = PI / centers.size
        // A little angular hysteresis keeps a held boundary from flickering between two actions.
        if (previous != null && previous in centers.indices) {
            val middle = -PI / 2 + (previous + 0.5) * step
            if (kotlin.math.abs(angle - middle) < step / 2 + PI / 60) return previous
        }
        return ((angle + PI / 2) / step).toInt().coerceIn(0, centers.lastIndex)
    }

    companion object {
        fun fit(count: Int, side: Side, anchorX: Float, anchorY: Float, area: SafeArea, density: Float, fontScale: Float): PetWheelGeometry {
            require(count > 0)
            val d = density.coerceAtLeast(0.1f)
            val pad = (14 * d).roundToInt().coerceAtLeast(1)
            val left = area.left + pad
            val top = area.top + pad
            val right = (area.screenW - area.right - pad).coerceAtLeast(left + 1)
            val bottom = (area.screenH - area.bottom - pad).coerceAtLeast(top + 1)
            val bw = (76 * d).roundToInt()
            val bh = (68 * d).roundToInt()
            val radius = (if (count >= 7) 220f else if (count >= 6) 196f else 172f) * d
            val extra = 14 * d // room for selection lift and scale, not just the resting labels
            val halfH = radius * cos(PI / (2 * count)).toFloat() + bh / 2f + extra
            val inwardW = radius + bw / 2f + extra
            val list = fontScale > 1.2f || bottom - top < 2 * halfH || right - left < inwardW + 32 * d
            if (list) {
                val w = (280 * d).roundToInt().coerceAtMost(right - left)
                val h = ((count * 52 + 12) * d * fontScale.coerceAtLeast(1f)).roundToInt().coerceAtMost(bottom - top)
                val x = (if (side == Side.LEFT) anchorX + 16 * d else anchorX - 16 * d - w).roundToInt().coerceIn(left, right - w)
                val y = (anchorY - h / 2f).roundToInt().coerceIn(top, bottom - h)
                return PetWheelGeometry(ScreenRect(x, y, x + w, y + h), side, anchorX, anchorY, 0f, bw, bh, emptyList(), d, true)
            }
            val cx = if (side == Side.LEFT) anchorX.coerceIn(left + 16 * d, right - inwardW) else anchorX.coerceIn(left + inwardW, right - 16 * d)
            val cy = anchorY.coerceIn(top + halfH, bottom - halfH)
            val sign = if (side == Side.LEFT) 1 else -1
            val centers = List(count) { i ->
                val a = -PI / 2 + (i + 0.5) * PI / count
                (cx + sign * radius * cos(a).toFloat()) to (cy + radius * sin(a).toFloat())
            }
            val x0 = if (side == Side.LEFT) cx - 16 * d else cx - inwardW
            val x1 = if (side == Side.LEFT) cx + inwardW else cx + 16 * d
            return PetWheelGeometry(ScreenRect(x0.toInt(), (cy - halfH).toInt(), kotlin.math.ceil(x1).toInt(), kotlin.math.ceil(cy + halfH).toInt()),
                side, cx, cy, radius, bw, bh, centers, d, false)
        }
    }
}

/** Selection belongs to one physical pointer stream; cancellation can never return an action. */
internal class PetWheelGesture(private val originX: Float, private val originY: Float, private val slop: Float) {
    private var moved = false
    var selected: Int? = null
        private set
    private var ended = false

    fun move(x: Float, y: Float, hit: () -> Int?): Int? {
        if (ended) return null
        val distance = hypot(x - originX, y - originY)
        if (distance > slop) moved = true
        selected = if (distance < slop * 2) null else hit()
        return selected
    }

    fun keepListOpen(cancelled: Boolean): Boolean = !ended && !cancelled && !moved

    fun finish(cancelled: Boolean): Int? {
        if (ended) return null
        ended = true
        return if (cancelled) null else selected
    }
}
