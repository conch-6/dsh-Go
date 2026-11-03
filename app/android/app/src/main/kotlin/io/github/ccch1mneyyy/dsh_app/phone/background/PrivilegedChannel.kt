package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.Bundle
import io.github.muntashirakon.adb.AdbStream

/**
 * One live link to the privileged engine. Two implementations, one contract: the driver
 * sends a request Bundle and gets a response Bundle, never caring whether the engine is
 * reached over a Shizuku binder or an adb stream. Calls are serialised by the caller
 * (the bridge's single worker thread); [execute] blocks.
 */
interface PrivilegedChannel {
    fun execute(request: Bundle): Bundle
    fun alive(): Boolean
    fun close()
}

/** Shizuku transport: a straight Binder call into [PrivilegedDisplayService]. */
class ShizukuChannel(private val remote: IPrivilegedDisplay) : PrivilegedChannel {
    override fun execute(request: Bundle): Bundle = remote.execute(request)
    override fun alive(): Boolean = runCatching { remote.asBinder().pingBinder() }.getOrDefault(false)
    override fun close() { /* UserService unbind is the starter's job */ }
}

/**
 * Self-ADB transport: framed Bundles over the adb shell stream that launched
 * [PrivilegedDisplayMain]. A response frame always follows its request frame on this
 * single stream, so one lock keeps request/response paired.
 */
class AdbChannel(private val stream: AdbStream) : PrivilegedChannel {
    private val session = AdbFramedSession(
        stream.openInputStream(), stream.openOutputStream(),
        transportAlive = { !stream.isClosed }, closeTransport = { stream.close() },
    )

    override fun execute(request: Bundle): Bundle = try {
        session.exchange(Bundles.marshal(request))?.let(Bundles::unmarshal) ?: unavailable("adb closed")
    } catch (e: Exception) {
        // Also retire a frame whose Bundle cannot be decoded; never reuse a partially read reply.
        session.close()
        unavailable("adb ${e.javaClass.simpleName}")
    }

    override fun alive(): Boolean = session.alive()

    override fun close() = session.close()

    private fun unavailable(detail: String) = Bundle().apply {
        putBoolean(Proto.OK, false); putString(Proto.ERROR, "deviceUnavailable"); putString(Proto.ERROR_DETAIL, detail)
    }
}
