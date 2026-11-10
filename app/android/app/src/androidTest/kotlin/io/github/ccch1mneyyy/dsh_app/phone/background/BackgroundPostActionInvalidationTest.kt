package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.Bundle
import android.test.AndroidTestCase
import io.github.ccch1mneyyy.dsh_app.phone.PhoneAction
import io.github.ccch1mneyyy.dsh_app.phone.PhoneAppIdentity
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger

/** Uses real Android Bundles, driver result processing and the original coordinate receipt state. */
@Suppress("DEPRECATION")
class BackgroundPostActionInvalidationTest : AndroidTestCase() {
    private class Fixture(
        val localAllowed: () -> Boolean = { false },
        val withText: Boolean = false,
    ) {
        var beforeReply: () -> Unit = {}
        var wrongOwner = false
        var replyPackage = "example.app"
        var replyUid = 10123
        val sends = AtomicInteger()
        val peer = object : PrivilegedChannel {
            override val backgroundLimit = 1
            override fun alive() = true
            override fun close() {}
            override fun execute(request: Bundle, beforeSend: () -> Unit): Bundle {
                beforeSend()
                sends.incrementAndGet()
                beforeReply()
                return Bundle().apply {
                    putInt(Proto.OWNER_SCOPE_VERSION, 1)
                    putString(Proto.OWNER, if (wrongOwner) "other-owner" else request.getString(Proto.OWNER))
                    putBoolean(Proto.OK, true)
                    putInt(Proto.TARGET_IDENTITY_VERSION, 1)
                    putString(Proto.PKG, replyPackage); putInt(Proto.TARGET_UID, replyUid)
                    if (request.getString(Proto.OP) == Proto.OP_RELEASE) {
                        putInt(Proto.RELEASE_RECEIPT, 1)
                        putBoolean("released", true); putBoolean(Proto.TASK_SCOPE_EMPTY, true)
                    } else if (withText) {
                        putBoolean(Proto.POOR, true); putBoolean(Proto.SECURE, false)
                        putInt(Proto.COUNT, 1)
                        putStringArray(Proto.A_ROLE, arrayOf("文本"))
                        putStringArray(Proto.A_LABEL, arrayOf("late-original-text"))
                    }
                    // Original default fixture still has no COUNT/SECURE or afterVisual.
                }
            }
        }
        val driver = BackgroundDisplay(channelProvider = { peer },
            journal = BackgroundResourceJournal({ null }, { true }).apply { load() },
            mayUse = { true }, admitUse = { action -> action(); true },
            localOcrAllowed = { localAllowed() })
        fun field(name: String) = BackgroundDisplay::class.java.getDeclaredField(name).apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val io = field("resourceIo").get(driver) as BackgroundDisplayIo<PrivilegedChannel>
        val coordinates = field("coordinateImage").get(driver) as BackgroundCoordinateImage
        val original = BackgroundCoordinateImage.Receipt("old-receipt", 48, 48)
        init {
            field("currentTarget").set(driver, PhoneAppIdentity("example.app", 10123))
            field("targetReady").setBoolean(driver, true)
            field("coordinateSupported").setBoolean(driver, true)
            io.call { io.startResource(peer, { beforeSend -> beforeSend(); Unit }) { true } }
            coordinates.candidate("b-old", original)
            driver.acceptVisualObservation("b-old")
        }
        fun finish() { check(io.release { true }) }
    }

    fun testSuccessfulBackWithNoPostSnapshotRevokesTheOldAcceptedReceipt() {
        val f = Fixture()
        try {
            val result = f.driver.perform(PhoneAction.Key("b-old", PhoneAction.GlobalKey.BACK))
            assertTrue(result.ok)
            assertNull(result.screen)
            assertEquals(1, f.sends.get())
            f.driver.acceptVisualObservation("b-old") // A delayed old acceptance must not revive it.
            assertNull(f.coordinates.take("b-old"))
        } finally { f.finish() }
    }

    fun testPostActionRetiresItsOcrTokenWithoutTouchingAnotherResource() {
        val f = Fixture(); val other = Fixture()
        try {
            f.field("coordinateOcrEpoch").set(f.driver, 7L)
            val result = f.driver.perform(PhoneAction.Key("b-old", PhoneAction.GlobalKey.BACK))
            assertTrue(result.ok)
            assertNull(result.screen)
            assertNull(f.field("coordinateOcrEpoch").get(f.driver))
            assertNull(f.coordinates.take("b-old"))
            assertEquals(other.original, other.coordinates.take("b-old"))
            assertEquals(0, other.sends.get())
        } finally { f.finish(); other.finish() }
    }

    fun testObservationReleasedAfterIdentityCheckCannotReviveOldTextOrNullPackage() {
        val entered = CountDownLatch(1); val answer = CountDownLatch(1)
        val f = Fixture(localAllowed = {
            entered.countDown()
            check(answer.await(5, TimeUnit.SECONDS))
            true
        }, withText = true)
        val result = AtomicReference<io.github.ccch1mneyyy.dsh_app.phone.ScreenSnapshot?>()
        val failure = AtomicReference<Throwable?>()
        val reader = Thread {
            try { result.set(f.driver.observe(false, false)) }
            catch (e: Throwable) { failure.set(e) }
        }.apply { start() }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            // localOcr is null: this existing policy callback is first reached after
            // requireIdentity, not by request preparation. No SDK is substituted.
            f.driver.seal()
            assertTrue(f.driver.release())
            assertNull(f.field("currentTarget").get(f.driver))
            answer.countDown(); reader.join(5_000)
            assertFalse(reader.isAlive)
            assertNull(result.get())
            assertTrue(failure.get() is IllegalStateException)
            assertNull(f.field("lastScreenId").get(f.driver))
            assertNull(f.coordinates.take("b-old"))
        } finally { answer.countDown(); reader.join(5_000); f.finish() }
    }

    fun testCurrentObservationStillPublishesItsOriginalTextAndPackage() {
        val f = Fixture(localAllowed = { true }, withText = true)
        try {
            val result = f.driver.observe(false, false)
            assertTrue(result.text.contains("late-original-text"))
            assertEquals("example.app", result.packageName)
            assertEquals(setOf("example.app"), result.readPackages)
        } finally { f.finish() }
    }

    fun testSealedPostActionScreenDoesNotRewriteSuccessfulActionAck() {
        val f = Fixture(withText = true)
        try {
            f.beforeReply = { f.driver.seal() }
            val result = f.driver.perform(PhoneAction.Key("b-old", PhoneAction.GlobalKey.BACK))
            assertTrue(result.ok)
            assertNull(result.screen)
            assertNull(f.field("lastScreenId").get(f.driver))
            assertNull(f.coordinates.take("b-old"))
            assertEquals(1, f.sends.get())
        } finally { f.beforeReply = {}; f.finish() }
    }

    fun testWrongOwnerReplyIsStillRejectedBeforeObservationPublication() {
        val f = Fixture(withText = true)
        try {
            f.wrongOwner = true
            var failure: Throwable? = null
            try { f.driver.observe(false, false) } catch (e: Throwable) { failure = e }
            assertTrue(failure is IllegalStateException)
            assertNull(f.field("lastScreenId").get(f.driver))
        } finally { f.finish() }
    }

    fun testSuccessfulLaunchWithoutScreenCannotReviveReadyAfterSeal() {
        for (sealAfterDispatch in listOf(false, true)) {
            val f = Fixture()
            try {
                // Seed only the already-allocated scope, matching this fixture's existing pin.
                // This exercises LAUNCH, not PROBE/ALLOCATE or journal persistence.
                val scope = f.field("resourceScope").get(f.driver)
                scope.javaClass.getDeclaredField("allocationReady").apply {
                    isAccessible = true; setBoolean(scope, true)
                }
                f.field("targetReady").setBoolean(f.driver, false)
                if (sealAfterDispatch) f.beforeReply = { f.driver.seal() }
                val result = f.driver.open(PhoneAppIdentity("example.app", 10123))
                assertTrue(result.ok)
                assertNull(result.screen)
                assertEquals(!sealAfterDispatch, f.field("targetReady").getBoolean(f.driver))
                assertEquals(1, f.sends.get())
            } finally { f.beforeReply = {}; f.finish() }
        }
    }

    fun testActionAcknowledgementStillRequiresTheExactPackageAndUid() {
        for ((pkg, uid) in listOf("example.app" to 10123, "other.app" to 10123, "example.app" to 10124)) {
            val f = Fixture()
            try {
                f.replyPackage = pkg; f.replyUid = uid
                val result = f.driver.perform(PhoneAction.Key("b-old", PhoneAction.GlobalKey.BACK))
                assertEquals(pkg == "example.app" && uid == 10123, result.ok)
                assertNull(result.screen)
                assertEquals(1, f.sends.get())
            } finally { f.finish() }
        }
    }
}
