package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

class PetWheelTest {
    private val area = SafeArea(412, 900, 0, 24, 0, 24)
    private fun fit(count: Int = 7, side: Side = Side.LEFT, y: Float = 460f, a: SafeArea = area, density: Float = 1f, fontScale: Float = 1f) =
        PetWheelGeometry.fit(count, side, if (side == Side.LEFT) 30f else a.screenW - 30f, y, a, density, fontScale)

    @Test fun everyActionIsReachableAndSidesAreExactMirrors() {
        for (count in 5..7) {
            val left = fit(count)
            val right = fit(count, Side.RIGHT)
            assertFalse(left.list)
            assertFalse(right.list)
            left.centers.forEachIndexed { i, p ->
                val mirrored = right.centers[i]
                assertEquals(area.screenW.toFloat(), p.first + mirrored.first, 0.01f)
                assertEquals(p.second, mirrored.second, 0.01f)
                assertEquals(i, left.hit(p.first, p.second))
                assertEquals(i, right.hit(mirrored.first, mirrored.second))
            }
        }
    }

    @Test fun selectionLiftAndButtonsStayWithinInsetsAtEitherVerticalEdge() {
        for (y in listOf(-100f, 20f, 460f, 900f, 1200f)) for (side in Side.entries) {
            val g = fit(side = side, y = y)
            assertTrue(g.bounds.left >= area.left)
            assertTrue(g.bounds.right <= area.screenW - area.right)
            assertTrue(g.bounds.top >= area.top)
            assertTrue(g.bounds.bottom <= area.screenH - area.bottom)
            for ((x, py) in g.centers) {
                assertTrue(x - g.buttonWidth / 2f - 12 >= g.bounds.left)
                assertTrue(x + g.buttonWidth / 2f + 12 <= g.bounds.right)
                assertTrue(py - g.buttonHeight / 2f - 12 >= g.bounds.top)
                assertTrue(py + g.buttonHeight / 2f + 12 <= g.bounds.bottom)
            }
        }
    }

    @Test fun neighboringButtonsHaveRoomEvenWhenLiftedAndScaled() {
        for (count in 5..7) {
            val g = fit(count)
            for (i in 0 until count - 1) {
                val a = g.centers[i]
                val b = g.centers[i + 1]
                assertTrue(kotlin.math.abs(a.first - b.first) > g.buttonWidth * 1.1f ||
                    kotlin.math.abs(a.second - b.second) > g.buttonHeight * 1.1f)
            }
        }
    }

    @Test fun centerOutsideAndBackHalfNeverSelect() {
        val g = fit()
        assertNull(g.hit(g.centerX, g.centerY))
        assertNull(g.hit(g.centerX + 30, g.centerY))
        assertNull(g.hit(g.centerX + g.radius * 0.43f, g.centerY))
        assertNull(g.hit(g.centerX - 5, g.centerY - 100))
        assertNull(g.hit(1000f, g.centerY))
        assertNull(g.hit(g.centerX + 400, g.centerY))
    }

    @Test fun boundaryHysteresisIsSmallAndDoesNotStickAcrossSectors() {
        val g = fit()
        val boundary = -PI / 2 + 3 * PI / 7
        val x = g.centerX + g.radius * cos(boundary + 0.01).toFloat()
        val y = g.centerY + g.radius * sin(boundary + 0.01).toFloat()
        assertEquals(3, g.hit(x, y))
        assertEquals(2, g.hit(x, y, 2))
        val next = g.centers[4]
        assertEquals(4, g.hit(next.first, next.second, 2))
    }

    @Test fun narrowLandscapeAndLargeFontsUseBoundedScrollableLabels() {
        for (a in listOf(SafeArea(220, 330, 8, 24, 8, 20), SafeArea(780, 340, 40, 0, 30, 24))) {
            val g = fit(a = a)
            assertTrue(g.list)
            assertTrue(g.bounds.width > 0 && g.bounds.height > 0)
            assertTrue(g.bounds.left >= a.left && g.bounds.right <= a.screenW - a.right)
            assertTrue(g.bounds.top >= a.top && g.bounds.bottom <= a.screenH - a.bottom)
        }
        assertTrue(fit(fontScale = 2f).list)
    }

    @Test fun geometryScalesInPhysicalPixels() {
        val normal = fit()
        val doubled = PetWheelGeometry.fit(7, Side.LEFT, 60f, 920f, SafeArea(824, 1800, 0, 48, 0, 48), 2f, 1f)
        assertFalse(doubled.list)
        assertEquals(normal.radius * 2, doubled.radius, 0.01f)
        assertEquals(normal.centerY * 2, doubled.centerY, 0.01f)
    }

    @Test fun returningToOriginOrLeavingWheelClearsPreviouslySelectedAction() {
        val g = fit()
        val gesture = PetWheelGesture(g.centerX, g.centerY, 10f)
        val p = g.centers[2]
        assertEquals(2, gesture.move(p.first, p.second) { g.hit(p.first, p.second) })
        assertNull(gesture.move(g.centerX, g.centerY) { 2 })
        assertNull(gesture.finish(false))
        val outside = PetWheelGesture(g.centerX, g.centerY, 10f)
        outside.move(p.first, p.second) { 2 }
        assertNull(outside.move(-100f, -100f) { g.hit(-100f, -100f) })
        assertNull(outside.finish(false))
    }

    @Test fun originalPointerSelectsExactlyOnceAndCancelNeverExecutes() {
        val gesture = PetWheelGesture(0f, 0f, 10f)
        gesture.move(100f, 0f) { 3 }
        assertEquals(3, gesture.finish(false))
        assertNull(gesture.finish(false))
        assertNull(gesture.move(100f, 0f) { 4 })
        val cancelled = PetWheelGesture(0f, 0f, 10f)
        cancelled.move(100f, 0f) { 3 }
        assertNull(cancelled.finish(true))
        assertNull(PetWheelGesture(0f, 0f, 10f).finish(false))
    }

    @Test fun onlyStationaryUncancelledFallbackReleaseCanContinueForNativeScrolling() {
        val stationary = PetWheelGesture(10f, 20f, 10f)
        stationary.move(12f, 21f) { 1 }
        assertTrue(stationary.keepListOpen(false))
        assertNull(stationary.finish(false))
        assertFalse(stationary.keepListOpen(false))
        val returning = PetWheelGesture(10f, 20f, 10f)
        returning.move(100f, 20f) { 2 }
        returning.move(10f, 20f) { null }
        assertFalse(returning.keepListOpen(false))
        assertNull(returning.finish(false))
        val cancelled = PetWheelGesture(10f, 20f, 10f)
        assertFalse(cancelled.keepListOpen(true))
        assertNull(cancelled.finish(true))
    }

    @Test fun captionIsCancelForBothSidesAndEveryMenuSize() {
        for (count in 5..7) for (side in Side.entries) {
            val g = fit(count, side)
            val pointer = PetWheelGesture(g.centerX, g.centerY, 10f)
            val p = g.centers[1]
            assertEquals(1, pointer.move(p.first, p.second) { g.hit(p.first, p.second) })
            val captionX = g.centerX + g.direction * g.radius * 0.43f
            assertNull(pointer.move(captionX, g.centerY) { g.hit(captionX, g.centerY, 1) })
            assertNull(pointer.finish(false))
        }
    }

    @Test fun fallbackRowsTranslateRawScreenCoordinatesIntoTheirClippedWindowSpace() {
        val g = fit(a = SafeArea(320, 400, 8, 24, 8, 20))
        assertTrue(g.list)
        assertTrue(g.bounds.left != 0 && g.bounds.top != 0)
        // getGlobalVisibleRect is clipped in the window/root coordinate space, not screen space.
        assertTrue(g.hitsVisibleRow(g.bounds.left + 30f, g.bounds.top + 40f, 6, 10, 100, 60))
        assertFalse(g.hitsVisibleRow(g.bounds.left + 30f, g.bounds.top + 65f, 6, 10, 100, 60))
        assertFalse(g.hitsVisibleRow(g.bounds.left + 2f, g.bounds.top + 40f, 6, 10, 100, 60))
        assertFalse(g.hitsVisibleRow(g.bounds.left + 30f, g.bounds.top + 5f, 6, 10, 100, 60))
    }

    @Test fun producerRotationOrLockInvalidationDoesNotReleaseCaptureVisibilityEarly() {
        val state = PetCaptureState()
        val request = state.begin()!!
        assertTrue(state.inFlight)
        assertNull(state.begin())
        state.invalidate()
        assertTrue(state.inFlight) // evaluate must still suppress re-show until the late callback
        assertFalse(state.finish(request))
        assertFalse(state.inFlight)
        assertFalse(state.finish(request))
        val next = state.begin()!!
        assertFalse(state.finish(request))
        assertTrue(state.inFlight)
        assertTrue(state.finish(next))
        assertFalse(state.inFlight)
    }
}
