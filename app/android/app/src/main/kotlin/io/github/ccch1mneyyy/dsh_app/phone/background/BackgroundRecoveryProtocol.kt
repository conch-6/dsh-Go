package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.Bundle

/** Only the fixed, private 3123 messages. Getter overloads are the actual Bundle parser,
 * also usable by JVM tests without constructing Android framework objects. */
internal object BackgroundRecoveryProtocol {
    fun birth(get: (String) -> Any?, contains: (String) -> Boolean): BackgroundResourceJournal.Birth? {
        if ((get(Proto.RESOURCE_RECOVERY_VERSION) as? Int) != 1) return null
        val available = if (contains(Proto.RECOVERY_PID_NS_AVAILABLE))
            get(Proto.RECOVERY_PID_NS_AVAILABLE) as? Boolean ?: return null else true
        return try {
            BackgroundResourceJournal.Birth(
                get(Proto.RECOVERY_PEER) as? String ?: return null,
                get(Proto.RECOVERY_BOOT) as? String ?: return null,
                get(Proto.RECOVERY_PID) as? Int ?: return null,
                get(Proto.RECOVERY_UID) as? Int ?: return null,
                get(Proto.RECOVERY_PID_NS_DEV) as? Long ?: return null,
                get(Proto.RECOVERY_PID_NS_INO) as? Long ?: return null,
                available,
            )
        } catch (_: IllegalArgumentException) { null }
    }

    /** Input is the body returned by OwnerScopeProtocol.first: it already validated the
     * original envelope, and rejects an accepted=false/ok=true contradiction before stripping it.
     */
    fun allocationId(get: (String) -> Any?): Int? {
        if ((get(Proto.OK) as? Boolean) != true ||
            (get(Proto.RESOURCE_RECOVERY_VERSION) as? Int) != 1) return null
        return (get(Proto.DISPLAY_ID) as? Int)?.takeIf { it > 0 }
    }

    fun retired(peer: String, get: (String) -> Any?): Boolean =
        (get(Proto.OK) as? Boolean) == true &&
            (get(Proto.RESOURCE_RECOVERY_VERSION) as? Int) == 1 &&
            get(Proto.RECOVERY_PEER) == peer && get(Proto.RECOVERY_KIND) == "peerRetired"

    /** get/contains come from the same returned Bundle. Absence is not a numeric sentinel. */
    fun recovered(record: BackgroundResourceJournal.Record, get: (String) -> Any?,
        contains: (String) -> Boolean): Boolean {
        if ((get(Proto.OK) as? Boolean) != true ||
            (get(Proto.RESOURCE_RECOVERY_VERSION) as? Int) != 1 ||
            get(Proto.RECOVERY_PEER) != record.birth.peer || get(Proto.OWNER) != record.owner) return false
        val kind = get(Proto.RECOVERY_KIND)
        if (kind != "previousBoot" && kind != "deadPeerEmpty") return false
        if (kind == "deadPeerEmpty" && (record.displayId == null || !record.birth.pidNsAvailable)) return false
        return if (record.displayId == null) !contains(Proto.DISPLAY_ID)
        else contains(Proto.DISPLAY_ID) && (get(Proto.DISPLAY_ID) as? Int) == record.displayId
    }

    /** The owner envelope is added by the existing OwnerScopeProtocol.first caller. */
    fun allocate(owner: String, purpose: String, viewport: String?): Bundle {
        require(purpose == "task" || purpose == "probe")
        require(if (purpose == "task") viewport == "portrait" || viewport == "landscape" else viewport == null)
        return Bundle().apply {
            putString(Proto.OP, Proto.OP_ALLOCATE)
            putString(Proto.OWNER, owner)
            putInt(Proto.RELEASE_RECEIPT, 1)
            putInt(Proto.RESOURCE_RECOVERY_VERSION, 1)
            putString(Proto.ALLOCATION_PURPOSE, purpose)
            if (purpose == "task") {
                putInt(Proto.SHORT_SIDE, 720)
                putString(Proto.VIEWPORT_PRESET, viewport)
            }
        }
    }

    fun retire(peer: String): Bundle = Bundle().apply {
        putString(Proto.OP, Proto.OP_RECOVERY_RETIRE)
        putInt(Proto.RESOURCE_RECOVERY_VERSION, 1)
        putString(Proto.RECOVERY_PEER, peer)
    }

    fun check(record: BackgroundResourceJournal.Record): Bundle = Bundle().apply {
        putString(Proto.OP, Proto.OP_RECOVERY_CHECK)
        putInt(Proto.RESOURCE_RECOVERY_VERSION, 1)
        putString(Proto.RECOVERY_PEER, record.birth.peer)
        putString(Proto.RECOVERY_BOOT, record.birth.boot)
        putInt(Proto.RECOVERY_PID, record.birth.pid)
        putInt(Proto.RECOVERY_UID, record.birth.uid)
        putLong(Proto.RECOVERY_PID_NS_DEV, record.birth.pidNsDev)
        putLong(Proto.RECOVERY_PID_NS_INO, record.birth.pidNsIno)
        if (!record.birth.pidNsAvailable) putBoolean(Proto.RECOVERY_PID_NS_AVAILABLE, false)
        putString(Proto.OWNER, record.owner)
        record.displayId?.let { putInt(Proto.DISPLAY_ID, it) }
    }
}
