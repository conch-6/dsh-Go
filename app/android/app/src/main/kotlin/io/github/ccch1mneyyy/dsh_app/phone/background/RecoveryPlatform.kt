package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.IBinder
import android.os.Process
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.view.Display
import java.io.File

/** Only fixed proc paths, signal zero and full raw Binder scope queries. Never removes a display. */
internal class RecoveryPlatform {
    fun birth(peer: String): ResourceRecovery.Birth {
        val boot = ResourceRecovery.uuid(File("/proc/sys/kernel/random/boot_id").readText().trim())
            ?: throw ResourceRecovery.Failure("recoveryUnavailable")
        // Some OEMs deny this namespace path. Missing evidence must not become a fake namespace.
        val ns = try { Os.stat("/proc/self/ns/pid") } catch (_: Exception) { null }
        val pid = Process.myPid(); val uid = Process.myUid()
        if (pid <= 0 || uid < 0 || ns != null && ns.st_ino <= 0) throw ResourceRecovery.Failure("recoveryUnavailable")
        return ResourceRecovery.Birth(peer, boot, pid, uid, ns?.st_dev ?: 0L, ns?.st_ino ?: 0L, ns != null)
    }

    private val managerType by lazy { Class.forName("android.hardware.display.IDisplayManager") }
    private val manager by lazy {
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "display") as? IBinder ?: throw ResourceRecovery.Failure("recoveryUnavailable")
        Class.forName("android.hardware.display.IDisplayManager\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, binder) ?: throw ResourceRecovery.Failure("recoveryUnavailable")
    }
    private val infoType by lazy { Class.forName("android.view.DisplayInfo") }
    private val infoMethod by lazy { managerType.getMethod("getDisplayInfo", Int::class.javaPrimitiveType) }
    private val virtualType by lazy { Display::class.java.getField("TYPE_VIRTUAL").getInt(null) }

    fun display(id: Int): ResourceRecovery.DisplayFact {
        val raw = infoMethod.invoke(manager, id)
        if (!infoType.isInstance(raw)) throw ResourceRecovery.Failure("recoveryUnknown")
        val actual = infoType.getField("displayId").getInt(raw)
        val name = infoType.getField("name").get(raw) as? String ?: throw ResourceRecovery.Failure("recoveryUnknown")
        val uid = infoType.getField("ownerUid").getInt(raw)
        if (actual != id) throw ResourceRecovery.Failure("recoveryUnknown")
        return ResourceRecovery.DisplayFact(id, name, uid, infoType.getField("type").getInt(raw) == virtualType)
    }

    fun displays(): List<ResourceRecovery.DisplayFact> {
        val ids = managerType.getMethod("getDisplayIds", Boolean::class.javaPrimitiveType).invoke(manager, true) as? IntArray
            ?: throw ResourceRecovery.Failure("recoveryUnknown")
        // A bounded query may fail, but may never truncate and claim absence.
        if (ids.isEmpty() || ids.size > 4096 || ids.any { it < 0 } || ids.toSet().size != ids.size || 0 !in ids)
            throw ResourceRecovery.Failure("recoveryUnknown")
        return ids.map(::display)
    }

    fun verify(current: ResourceRecovery.Birth, old: ResourceRecovery.Check, tasksEmpty: (Int) -> Boolean): String =
        ResourceRecovery.verify(current, old, { pid ->
            try { Os.kill(pid, 0); false }
            catch (e: ErrnoException) {
                if (e.errno == OsConstants.ESRCH) true else throw ResourceRecovery.Failure("recoveryUnknown")
            }
        }, ::displays, tasksEmpty)
}
