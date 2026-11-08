package io.github.ccch1mneyyy.dsh_app.phone.background

import android.content.Context
import android.os.Bundle
import io.github.ccch1mneyyy.dsh_app.phone.selfcheck.TargetContract

/** Bound before publication; no platform allocation occurs in this value or Core construction. */
internal data class HostedScope(
    val owner: String,
    val probe: Boolean = false,
    val target: SelfCheckTargetRequest? = null,
    val recovery: Boolean = false,
) {
    val maintenance: Boolean get() = probe || target != null
}

/** Only fixed completion facts survive Core retirement; never a screen, reader, or arbitrary Bundle. */
internal data class HostedRelease(val owner: String, val neverCreated: Boolean, val target: SelfCheckTargetCompletion?) {
    fun reply(request: Bundle): Bundle? {
        if (target != null) {
            if (SelfCheckTargetRelease.parse(request.keySet()) { request.get(it) } != target.request) return null
        } else if (request.keySet() != setOf(Proto.OP, Proto.OWNER, Proto.RELEASE_RECEIPT) ||
            request.get(Proto.RELEASE_RECEIPT) != 1 || request.get(Proto.OWNER) != owner || request.get(Proto.OP) != Proto.OP_RELEASE) return null
        return Bundle().apply {
            putBoolean(Proto.OK, true); putString(Proto.OWNER, owner); putInt(Proto.RELEASE_RECEIPT, 1)
            if (neverCreated) putBoolean("neverCreated", true)
            else { putBoolean("released", true); putBoolean(Proto.TASK_SCOPE_EMPTY, true) }
            target?.let {
                putInt(Proto.SELF_CHECK_TARGET_C2_VERSION, 1)
                putString(Proto.TARGET_RUN, it.request.run); putString(Proto.RELEASE_NONCE, it.request.nonce)
                putString(Proto.FINAL_MAIN_VECTOR, it.main.vector.wire)
                putString(Proto.FINAL_GLOBAL_FOCUS, it.main.focus.wire)
            }
        }
    }
}

/** Actual Binder/framed-server router; resource Core instances have independent fixed owners. */
internal class PrivilegedDisplayHost(private val context: Context) {
    val peerInstance: String = java.util.UUID.randomUUID().toString()
    private val trees = PrivilegedTreeAccess(context)
    private val legacy = PrivilegedDisplayCore(context, trees)
    private val scopes = OwnerScopes<PrivilegedDisplayCore, HostedRelease>()
    private val recoveryPlatform = RecoveryPlatform()
    private val birth by lazy { runCatching { recoveryPlatform.birth(peerInstance) }.getOrNull() }
    @Volatile private var retirementComplete = false

    fun handle(request: Bundle): Bundle {
        val op = request.get(Proto.OP) as? String ?: return failure("invalidArguments")
        if (op == Proto.OP_PROBE) return legacy.handle(request).apply {
            if (get(Proto.OK) == true) {
                putInt(Proto.OWNER_SCOPE_VERSION, 1); putInt(Proto.SCOPE_LIMIT, 3)
                birth?.let { value ->
                    putInt(Proto.RESOURCE_RECOVERY_VERSION, 1); putString(Proto.RECOVERY_PEER, value.peer)
                    putString(Proto.RECOVERY_BOOT, value.boot); putInt(Proto.RECOVERY_PID, value.pid)
                    putInt(Proto.RECOVERY_UID, value.uid); putLong(Proto.RECOVERY_PID_NS_DEV, value.nsDev)
                    putLong(Proto.RECOVERY_PID_NS_INO, value.nsIno)
                }
            }
        }
        if (op == Proto.OP_RECOVERY_RETIRE) return retire(request)
        if (op == Proto.OP_RECOVERY_CHECK) return checkRecovery(request)
        if (op == Proto.OP_DESTROY || op == Proto.OP_GRANT_SECURE_SETTINGS) {
            scopes.enterGlobal()?.let { return failure(it) }
            return try {
                if (!trees.ready() || op == Proto.OP_GRANT_SECURE_SETTINGS && legacy.hasResources()) failure("releasePending")
                else legacy.handle(request).also {
                    if (op == Proto.OP_DESTROY && it.get(Proto.OK) == true && !legacy.previewDrained()) {
                        it.putBoolean(Proto.OK, false); it.putString(Proto.ERROR, "releasePending")
                    }
                }
            } finally { scopes.leaveGlobal() }
        }
        if (!request.containsKey(Proto.OWNER_SCOPE_VERSION)) {
            if (op == Proto.OP_ALLOCATE || request.containsKey(Proto.RESOURCE_RECOVERY_VERSION)) return failure("invalidArguments")
            scopes.enterGlobal(legacyResource = true)?.let { return failure(it) }
            return try { legacy.handle(request) } finally { scopes.leaveGlobal() }
        }
        val owner = request.get(Proto.OWNER) as? String
        if (request.get(Proto.OWNER_SCOPE_VERSION) !is Int || request.get(Proto.OWNER_SCOPE_VERSION) != 1 ||
            owner == null || !TargetContract.validRun(owner)) return failure("invalidArguments")
        val inner = Bundle(request).apply { remove(Proto.OWNER_SCOPE_VERSION) }
        val opening = op in setOf(Proto.OP_ALLOCATE, Proto.OP_CREATE, Proto.OP_LAUNCH, Proto.OP_SELF_CHECK_PROBE, Proto.OP_SELF_CHECK_TARGET_CREATE)
        val initial = if (opening) initial(inner, owner) else null
        // Known identities never receive scopeAccepted=false for malformed subsequent requests.
        val entry = scopes.enter(owner, opening && initial != null, initial?.maintenance == true, op == Proto.OP_RELEASE) {
            PrivilegedDisplayCore(context, trees, checkNotNull(initial))
        }
        val response = when (entry) {
            is OwnerScopes.Entry.Refused -> failure(if (opening && initial == null) "invalidArguments" else entry.code).apply {
                if (opening) {
                    if (!entry.unknown || legacy.knowsOwner(owner)) putBoolean(Proto.SCOPE_ACCEPTED, true)
                    else putBoolean(Proto.SCOPE_ACCEPTED, false)
                }
            }
            is OwnerScopes.Entry.Completed -> entry.receipt.reply(inner) ?: failure("identityChanged")
            is OwnerScopes.Entry.Acquired -> {
                var completed: HostedRelease? = null
                try {
                    // Only target CREATE selection is stripped; its original nonce parser stays exact.
                    val selected = inner.containsKey(Proto.RESOURCE_RECOVERY_VERSION)
                    val targetCreate = op == Proto.OP_SELF_CHECK_TARGET_CREATE
                    val reply = if (selected && (birth == null ||
                        targetCreate && (!entry.record.core.recoveryMode() || inner.get(Proto.RESOURCE_RECOVERY_VERSION) !is Int ||
                            inner.get(Proto.RESOURCE_RECOVERY_VERSION) != 1) ||
                        !targetCreate && op != Proto.OP_ALLOCATE)) failure("invalidArguments")
                    else entry.record.core.handle(
                        if (targetCreate && selected) Bundle(inner).apply { remove(Proto.RESOURCE_RECOVERY_VERSION) } else inner)
                    if (op == Proto.OP_RELEASE && reply.get(Proto.OK) == true) {
                        if (entry.record.core.previewDrained()) completed = entry.record.core.completedRelease()
                        else { reply.putBoolean(Proto.OK, false); reply.putString(Proto.ERROR, "releasePending") }
                    }
                    if (opening) reply.putBoolean(Proto.SCOPE_ACCEPTED, true)
                    reply
                } finally { scopes.leave(entry.record, completed) }
            }
        }
        return response.apply { putInt(Proto.OWNER_SCOPE_VERSION, 1); putString(Proto.OWNER, owner) }
    }

    private fun initial(request: Bundle, owner: String): HostedScope? {
        if (request.get(Proto.RELEASE_RECEIPT) !is Int || request.get(Proto.RELEASE_RECEIPT) != 1) return null
        if (request.containsKey(Proto.RESOURCE_RECOVERY_VERSION) &&
            request.get(Proto.OP) !in setOf(Proto.OP_ALLOCATE, Proto.OP_SELF_CHECK_TARGET_CREATE)) return null
        return when (request.get(Proto.OP)) {
            Proto.OP_ALLOCATE -> if (birth == null) null else ResourceRecovery.allocation(request.keySet()) { request.get(it) }
                ?.let { HostedScope(it.owner, probe = it.probe, recovery = true) }
            Proto.OP_SELF_CHECK_PROBE -> SelfCheckProbeRequest.owner(request.keySet()) { request.get(it) }
                ?.let { HostedScope(it, probe = true) }
            Proto.OP_SELF_CHECK_TARGET_CREATE -> {
                val recovery = request.containsKey(Proto.RESOURCE_RECOVERY_VERSION)
                if (recovery && (birth == null || ResourceRecovery.uuid(owner) == null ||
                    request.get(Proto.RESOURCE_RECOVERY_VERSION) !is Int ||
                    request.get(Proto.RESOURCE_RECOVERY_VERSION) != 1)) null
                else {
                    val keys = if (recovery) request.keySet() - Proto.RESOURCE_RECOVERY_VERSION else request.keySet()
                    SelfCheckTargetRequest.parse(keys) { request.get(it) }?.let { HostedScope(it.owner, target = it, recovery = recovery) }
                }
            }
            Proto.OP_CREATE, Proto.OP_LAUNCH -> HostedScope(owner)
            else -> null
        }
    }

    private fun retire(request: Bundle): Bundle {
        val expected = ResourceRecovery.retire(request.keySet()) { request.get(it) }
            ?: return failure("invalidArguments")
        if (expected != peerInstance) return failure("identityChanged")
        if (birth == null) return failure("recoveryUnavailable")
        if (retirementComplete) return retiredReply()
        val originals = scopes.beginRetire() ?: return failure("scopeBusy")
        var complete = false
        return try {
            // All original cores stay reachable on failure. No C2 nonce or MAIN sample is fabricated.
            for (record in originals) if (!record.core.retireResources()) return failure("releasePending")
            if (!legacy.retireResources() || !trees.ready()) return failure("releasePending")
            complete = true
            retirementComplete = true
            retiredReply()
        } catch (_: Throwable) { failure("releasePending") }
        finally { scopes.finishRetire(complete) }
    }

    private fun retiredReply() = Bundle().apply {
        putBoolean(Proto.OK, true); putInt(Proto.RESOURCE_RECOVERY_VERSION, 1)
        putString(Proto.RECOVERY_PEER, peerInstance); putString(Proto.RECOVERY_KIND, "peerRetired")
    }

    private fun checkRecovery(request: Bundle): Bundle {
        val old = ResourceRecovery.check(request.keySet()) { request.get(it) } ?: return failure("invalidArguments")
        val current = birth ?: return failure("recoveryUnavailable")
        scopes.enterGlobal()?.let { return failure(it) }
        return try {
            if (legacy.hasResources() || !trees.ready()) return failure("scopeBusy")
            val kind = recoveryPlatform.verify(current, old, legacy::rootTasksEmpty)
            Bundle().apply {
                putBoolean(Proto.OK, true); putInt(Proto.RESOURCE_RECOVERY_VERSION, 1)
                putString(Proto.RECOVERY_PEER, old.birth.peer); putString(Proto.OWNER, old.owner)
                putString(Proto.RECOVERY_KIND, kind); old.displayId?.let { putInt(Proto.DISPLAY_ID, it) }
            }
        } catch (e: ResourceRecovery.Failure) { failure(e.code) }
        catch (_: Throwable) { failure("recoveryUnknown") }
        finally { scopes.leaveGlobal() }
    }

    private fun failure(code: String) = Bundle().apply { putBoolean(Proto.OK, false); putString(Proto.ERROR, code) }
}
