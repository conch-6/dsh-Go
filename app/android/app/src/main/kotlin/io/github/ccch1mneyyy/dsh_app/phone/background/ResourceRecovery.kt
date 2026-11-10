package io.github.ccch1mneyyy.dsh_app.phone.background

import java.util.UUID

/** Fixed request parsing and the actual recovery decision, shared by Host and platform reader. */
internal object ResourceRecovery {
    data class Birth(val peer: String, val boot: String, val pid: Int, val uid: Int, val nsDev: Long, val nsIno: Long,
        val nsAvailable: Boolean = true)
    data class Check(val birth: Birth, val owner: String, val displayId: Int?)
    data class Allocation(val owner: String, val probe: Boolean, val viewport: String?)
    data class DisplayFact(val id: Int, val name: String, val uid: Int, val virtual: Boolean)
    class Failure(val code: String) : Exception()

    fun uuid(value: Any?): String? = (value as? String)?.takeIf {
        runCatching { UUID.fromString(it).toString() == it }.getOrDefault(false)
    }
    fun tag(owner: String): String = "dsh-background-$owner"
    private fun version(value: (String) -> Any?): Boolean = value(Proto.RESOURCE_RECOVERY_VERSION) is Int &&
        value(Proto.RESOURCE_RECOVERY_VERSION) == 1

    fun allocation(keys: Set<String>, value: (String) -> Any?): Allocation? {
        val base = setOf(Proto.OP, Proto.OWNER, Proto.RELEASE_RECEIPT, Proto.RESOURCE_RECOVERY_VERSION, Proto.ALLOCATION_PURPOSE)
        if (value(Proto.OP) != Proto.OP_ALLOCATE || !version(value) || value(Proto.RELEASE_RECEIPT) !is Int ||
            value(Proto.RELEASE_RECEIPT) != 1) return null
        val owner = uuid(value(Proto.OWNER)) ?: return null
        return when (value(Proto.ALLOCATION_PURPOSE)) {
            "probe" -> if (keys == base) Allocation(owner, true, null) else null
            "task" -> if (keys == base + setOf(Proto.SHORT_SIDE, Proto.VIEWPORT_PRESET) &&
                value(Proto.SHORT_SIDE) is Int && value(Proto.SHORT_SIDE) == 720 &&
                value(Proto.VIEWPORT_PRESET) in setOf("portrait", "landscape"))
                Allocation(owner, false, value(Proto.VIEWPORT_PRESET) as String) else null
            else -> null
        }
    }

    fun retire(keys: Set<String>, value: (String) -> Any?): String? =
        if (keys == setOf(Proto.OP, Proto.RESOURCE_RECOVERY_VERSION, Proto.RECOVERY_PEER) &&
            value(Proto.OP) == Proto.OP_RECOVERY_RETIRE && version(value)) uuid(value(Proto.RECOVERY_PEER)) else null

    fun check(keys: Set<String>, value: (String) -> Any?): Check? {
        val base = setOf(Proto.OP, Proto.RESOURCE_RECOVERY_VERSION, Proto.RECOVERY_PEER, Proto.RECOVERY_BOOT,
            Proto.RECOVERY_PID, Proto.RECOVERY_UID, Proto.RECOVERY_PID_NS_DEV, Proto.RECOVERY_PID_NS_INO, Proto.OWNER)
        if (keys - setOf(Proto.DISPLAY_ID, Proto.RECOVERY_PID_NS_AVAILABLE) != base ||
            value(Proto.OP) != Proto.OP_RECOVERY_CHECK || !version(value)) return null
        val peer = uuid(value(Proto.RECOVERY_PEER)) ?: return null
        val boot = uuid(value(Proto.RECOVERY_BOOT)) ?: return null
        val owner = uuid(value(Proto.OWNER)) ?: return null
        val pid = (value(Proto.RECOVERY_PID) as? Int)?.takeIf { it > 0 } ?: return null
        val uid = (value(Proto.RECOVERY_UID) as? Int)?.takeIf { it >= 0 } ?: return null
        val dev = value(Proto.RECOVERY_PID_NS_DEV) as? Long ?: return null
        val ino = value(Proto.RECOVERY_PID_NS_INO) as? Long ?: return null
        val available = if (Proto.RECOVERY_PID_NS_AVAILABLE in keys)
            value(Proto.RECOVERY_PID_NS_AVAILABLE) as? Boolean ?: return null else true
        if (if (available) ino <= 0 else dev != 0L || ino != 0L) return null
        val id = if (Proto.DISPLAY_ID in keys) (value(Proto.DISPLAY_ID) as? Int)?.takeIf { it > 0 } ?: return null else null
        return Check(Birth(peer, boot, pid, uid, dev, ino, available), owner, id)
    }

    /** Readers perform real platform calls; unknown never becomes an empty collection or false PID. */
    fun verify(current: Birth, old: Check, pidAbsent: (Int) -> Boolean,
               displays: () -> List<DisplayFact>, tasksEmpty: (Int) -> Boolean): String {
        if (current.boot != old.birth.boot) return "previousBoot"
        if (!current.nsAvailable || !old.birth.nsAvailable || current.nsIno <= 0 || old.birth.nsIno <= 0 ||
            current.nsDev != old.birth.nsDev || current.nsIno != old.birth.nsIno) throw Failure("recoveryUnknown")
        if (!pidAbsent(old.birth.pid)) throw Failure("recoveryUnknown")
        val id = old.displayId ?: throw Failure("recoveryUnknown")
        if (current.uid != 0 && current.uid != 1000 && current.uid != old.birth.uid) throw Failure("recoveryUnknown")
        val all = displays()
        if (all.any { it.name == tag(old.owner) }) throw Failure("recoveryPresent")
        if (all.any { it.id == id }) throw Failure("recoveryConflict")
        if (!tasksEmpty(id)) throw Failure("recoveryPresent")
        return "deadPeerEmpty"
    }
}
