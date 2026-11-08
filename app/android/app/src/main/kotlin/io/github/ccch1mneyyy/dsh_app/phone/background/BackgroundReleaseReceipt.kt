package io.github.ccch1mneyyy.dsh_app.phone.background

/** Both exact receipt variants are consumed by the real Bundle path; old ACKs prove neither. */
internal object BackgroundReleaseReceipt {
    fun accepts(expectedOwner: String, version: Any?, owner: Any?, ok: Any?, released: Any?, taskScopeEmpty: Any?, neverCreated: Any? = null): Boolean {
        if (version !is Int || version != 1 || owner !is String || owner != expectedOwner || ok !is Boolean || !ok) return false
        return if (neverCreated == null) released is Boolean && released && taskScopeEmpty is Boolean && taskScopeEmpty
        else neverCreated is Boolean && neverCreated && released == null && taskScopeEmpty == null
    }
}
