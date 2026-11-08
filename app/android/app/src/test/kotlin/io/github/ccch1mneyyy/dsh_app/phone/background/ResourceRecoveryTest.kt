package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

/** Calls the same parser/decision functions used by Host and RecoveryPlatform; no Android stubs. */
class ResourceRecoveryTest {
    private val peer = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val boot = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private val owner = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private val current = ResourceRecovery.Birth(peer, boot, 100, 2000, 7L, 9L)
    private fun old(id: Int? = 12, uid: Int = 2000) = ResourceRecovery.Check(
        current.copy(peer = "dddddddd-dddd-4ddd-8ddd-dddddddddddd", pid = 99, uid = uid), owner, id)

    private fun failure(code: String, body: () -> Unit) {
        try { body(); fail("Expected $code") }
        catch (e: ResourceRecovery.Failure) { assertEquals(code, e.code) }
    }

    private fun request() = linkedMapOf<String, Any>(
        Proto.OP to Proto.OP_RECOVERY_CHECK, Proto.RESOURCE_RECOVERY_VERSION to 1,
        Proto.RECOVERY_PEER to peer, Proto.RECOVERY_BOOT to boot, Proto.RECOVERY_PID to 99,
        Proto.RECOVERY_UID to 2000, Proto.RECOVERY_PID_NS_DEV to 7L,
        Proto.RECOVERY_PID_NS_INO to 9L, Proto.OWNER to owner, Proto.DISPLAY_ID to 12,
    )

    @Test fun exactCheckRejectsWrongCodecTypesMissingIdentityAndExtraPayload() {
        val good = request()
        assertEquals(12, ResourceRecovery.check(good.keys, good::get)?.displayId)
        for ((key, value) in listOf(
            Proto.RESOURCE_RECOVERY_VERSION to 1L,
            Proto.RECOVERY_PID to 99L,
            Proto.RECOVERY_UID to -1,
            Proto.RECOVERY_PID_NS_INO to 9,
            Proto.RECOVERY_PID_NS_INO to 0L,
            Proto.DISPLAY_ID to 0,
            Proto.RECOVERY_PEER to peer.uppercase(),
        )) {
            val bad = request().apply { put(key, value) }
            assertNull(ResourceRecovery.check(bad.keys, bad::get))
        }
        val extra = request().apply { put("text", "not accepted") }
        assertNull(ResourceRecovery.check(extra.keys, extra::get))
        val missing = request().apply { remove(Proto.RECOVERY_BOOT) }
        assertNull(ResourceRecovery.check(missing.keys, missing::get))
        val noId = request().apply { remove(Proto.DISPLAY_ID) }
        assertNull(checkNotNull(ResourceRecovery.check(noId.keys, noId::get)).displayId)
    }

    @Test fun allocateAcceptsOnlyFixedTaskOrProbeShapes() {
        val probe = linkedMapOf<String, Any>(
            Proto.OP to Proto.OP_ALLOCATE, Proto.OWNER to owner, Proto.RELEASE_RECEIPT to 1,
            Proto.RESOURCE_RECOVERY_VERSION to 1, Proto.ALLOCATION_PURPOSE to "probe",
        )
        assertTrue(checkNotNull(ResourceRecovery.allocation(probe.keys, probe::get)).probe)
        val extraProbe = probe + (Proto.SHORT_SIDE to 360)
        assertNull(ResourceRecovery.allocation(extraProbe.keys, extraProbe::get))
        val task = probe + mapOf(Proto.ALLOCATION_PURPOSE to "task", Proto.SHORT_SIDE to 720,
            Proto.VIEWPORT_PRESET to "landscape")
        assertEquals("landscape", ResourceRecovery.allocation(task.keys, task::get)?.viewport)
        for (bad in listOf(task + (Proto.SHORT_SIDE to 720L), task + (Proto.VIEWPORT_PRESET to "custom"),
            task + (Proto.PKG to "example.not.allowed"), task - Proto.VIEWPORT_PRESET)) {
            assertNull(ResourceRecovery.allocation(bad.keys, bad::get))
        }
    }

    @Test fun retireIsAnExactPeerRequestNotAnOwnerOrArbitraryPidCommand() {
        val value = mapOf<String, Any>(Proto.OP to Proto.OP_RECOVERY_RETIRE,
            Proto.RESOURCE_RECOVERY_VERSION to 1, Proto.RECOVERY_PEER to peer)
        assertEquals(peer, ResourceRecovery.retire(value.keys, value::get))
        val extra = value + (Proto.OWNER to owner)
        assertNull(ResourceRecovery.retire(extra.keys, extra::get))
        val bad = value + (Proto.RECOVERY_PEER to "")
        assertNull(ResourceRecovery.retire(bad.keys, bad::get))
    }

    @Test fun previousBootUsesNoPidDisplayOrTaskQueryEvenWithoutOriginalId() {
        val original = old(null).let { it.copy(birth = it.birth.copy(boot = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")) }
        assertEquals("previousBoot", ResourceRecovery.verify(current, original,
            { error("must not query a reused PID") }, { error("must not query new boot displays") },
            { error("must not query reused display IDs") }))
    }

    @Test fun namespaceMismatchAndLivePidCannotReachDisplayQuery() {
        val different = old().let { it.copy(birth = it.birth.copy(nsIno = 10L)) }
        failure("recoveryUnknown") {
            ResourceRecovery.verify(current, different, { error("wrong namespace") },
                { error("no display read") }, { error("no task read") })
        }
        val calls = mutableListOf<Int>()
        failure("recoveryUnknown") {
            ResourceRecovery.verify(current, old(), { calls += it; false },
                { error("live PID") }, { error("live PID") })
        }
        assertEquals(listOf(99), calls)
    }

    @Test fun sameBootMissingIdAndPrivateVisibilityGapStayUnknown() {
        for (original in listOf(old(null), old(uid = 0))) {
            failure("recoveryUnknown") {
                ResourceRecovery.verify(current, original, { true },
                    { error("no complete target visibility or no original ID") }, { error("no task query") })
            }
        }
    }

    @Test fun matchingTagAndReusedIdAreNotAbsenceAndNeverQueryTasks() {
        failure("recoveryPresent") {
            ResourceRecovery.verify(current, old(), { true },
                { listOf(ResourceRecovery.DisplayFact(27, ResourceRecovery.tag(owner), 2000, true)) },
                { error("target still present") })
        }
        failure("recoveryConflict") {
            ResourceRecovery.verify(current, old(), { true },
                { listOf(ResourceRecovery.DisplayFact(12, "other display", 2000, true)) },
                { error("reused numerical ID") })
        }
    }

    @Test fun emptyTaskProofUsesOnlyOriginalIdAfterCompleteDisplayObservation() {
        val order = mutableListOf<String>()
        val kind = ResourceRecovery.verify(current.copy(uid = 0), old(uid = 12345),
            { order += "pid:$it"; true },
            { order += "displays"; listOf(ResourceRecovery.DisplayFact(0, "main", 1000, false)) },
            { order += "tasks:$it"; true })
        assertEquals("deadPeerEmpty", kind)
        assertEquals(listOf("pid:99", "displays", "tasks:12"), order)
        failure("recoveryPresent") {
            ResourceRecovery.verify(current, old(), { true }, { emptyList() }, { false })
        }
    }

    @Test fun incompletePlatformReadsPropagateInsteadOfInventingAnEmptyScope() {
        val originalFailure = IllegalStateException("controlled reader failure")
        try {
            ResourceRecovery.verify(current, old(), { true }, { throw originalFailure }, { error("must not query") })
            fail("Unknown read must propagate to Host's fixed recoveryUnknown mapping")
        } catch (e: IllegalStateException) { assertSame(originalFailure, e) }
        try {
            ResourceRecovery.verify(current, old(), { true }, { emptyList() }, { throw originalFailure })
            fail("Unknown task read must not pass")
        } catch (e: IllegalStateException) { assertSame(originalFailure, e) }
    }
}
