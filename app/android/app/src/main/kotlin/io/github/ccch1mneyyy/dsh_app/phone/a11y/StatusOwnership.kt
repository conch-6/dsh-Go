package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.phone.TaskControls

/** Main-queue confined ownership of the displayed status, independent of prompt cards.
 * Checks only short task state. Platform/UI work always runs after the check returns. */
internal class StatusOwnership {
    private var current: ((() -> Unit) -> Boolean)? = null

    /** 暂停 / 停止 / 插话 of the task whose status is displayed; never re-resolved at tap time. */
    var controls: TaskControls? = null
        private set

    fun publish(ifCurrent: (() -> Unit) -> Boolean): Boolean = publish(ifCurrent) { null }

    /** [capture] runs inside [ifCurrent], so the controls belong to the very status being shown. */
    fun publish(ifCurrent: (() -> Unit) -> Boolean, capture: () -> TaskControls?): Boolean {
        var captured: TaskControls? = null
        if (!ifCurrent { captured = capture() }) return false
        current = ifCurrent
        controls = captured
        return true
    }

    fun clear() { current = null; controls = null }

    /** A newer task may invalidate an old cleanup ticket without owning the old status. */
    fun takeStale(): Boolean {
        val owner = current ?: return false
        if (owner {}) return false
        clear()
        return true
    }
}
