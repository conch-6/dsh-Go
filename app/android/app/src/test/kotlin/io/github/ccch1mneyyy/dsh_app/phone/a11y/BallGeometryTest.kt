package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.pet.Dock
import io.github.ccch1mneyyy.dsh_app.pet.EdgeSnap
import io.github.ccch1mneyyy.dsh_app.pet.SafeArea
import io.github.ccch1mneyyy.dsh_app.pet.Side
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The ball against the capsule and the screen sides, at 2.625 px/dp (a 1080 px phone, 411 dp wide). */
class BallGeometryTest {
    private val density = 2.625f
    private fun dp(v: Int) = Math.round(v * density)

    private val area = SafeArea(1080, 2400, left = 0, top = 96, right = 0, bottom = 63)
    private val ball = dp(OverlayBall.BALL_DP)
    private val pad = dp(OverlayBall.PAD_DP)
    private val size = ball + 2 * pad
    private val edge = dp(OverlayBall.EDGE_DP)
    private val margin = BallGeometry.margin(edge, pad)

    // The capsule as ControlOverlay places it: centred, its root padding the surface, under the status bar.
    private val padX = dp(OverlayCapsule.PAD_X_DP)
    private val padTop = dp(OverlayCapsule.PAD_TOP_DP)
    private val capsuleW = dp(240)
    private val windowW = capsuleW + 2 * padX
    private val windowX = BallGeometry.centredX(area.screenW, windowW)
    private val windowY = area.top + dp(CapsuleMetrics.TOP_GAP_DP) - padTop

    private fun end(side: Side) = BallGeometry.ballOver(
        windowX, windowY, padX, padTop, BallGeometry.circleLeft(0, capsuleW, ball, side), 0, pad,
    )

    @Test fun theBallIsTheCapsulesHeight() {
        // One object: the ball is the capsule's end circle, and every form has the same corner.
        assertEquals(CapsuleMetrics.HEIGHT_DP, OverlayBall.BALL_DP)
        assertEquals(CapsuleMetrics.HEIGHT_DP / 2, CapsuleMetrics.RADIUS_DP)
        assertTrue(OverlayBall.BALL_DP >= 48)
    }

    @Test fun dockedBallsSitTheSameGapFromEitherSide() {
        val left = EdgeSnap.position(Dock(Side.LEFT, 0.3f), size, size, area, margin)
        val right = EdgeSnap.position(Dock(Side.RIGHT, 0.3f), size, size, area, margin)
        val leftGap = left.x + pad
        val rightGap = area.screenW - (right.x + pad + ball)
        assertEquals(edge, leftGap)
        assertEquals(edge, rightGap)
        // Mirror images: same height.
        assertEquals(left.y, right.y)
    }

    @Test fun theFoldStartsOnTheCapsulesEndCircle() {
        val surfaceLeft = windowX + padX
        val surfaceTop = windowY + padTop
        val r = end(Side.RIGHT)
        assertEquals(surfaceLeft + capsuleW - ball, r.x + pad)
        assertEquals(surfaceTop, r.y + pad)
        val l = end(Side.LEFT)
        assertEquals(surfaceLeft, l.x + pad)
        assertEquals(r.y, l.y)
        // The capsule's top is the gap under the status bar.
        assertEquals(area.top + dp(CapsuleMetrics.TOP_GAP_DP), r.y + pad)
    }

    @Test fun theTwoEndsAreMirrorImagesAboutTheScreensCentre() {
        val r = end(Side.RIGHT)
        val l = end(Side.LEFT)
        val leftOfLeft = l.x + pad
        val rightOfRight = r.x + pad + ball
        assertTrue(kotlin.math.abs((leftOfLeft + rightOfRight) - area.screenW) <= 1)
    }

    @Test fun aCircleAtEitherEndOfAWideCard() {
        // From the card, the fold goes to the header's end: the card's corner circle.
        val cardW = CapsuleMetrics.maxPx(area.screenW, density)
        assertEquals(cardW - ball, BallGeometry.circleLeft(0, cardW, ball, Side.RIGHT))
        assertEquals(0, BallGeometry.circleLeft(0, cardW, ball, Side.LEFT))
        assertEquals(30, BallGeometry.circleLeft(30, 30 + cardW, ball, Side.LEFT))
    }
}
