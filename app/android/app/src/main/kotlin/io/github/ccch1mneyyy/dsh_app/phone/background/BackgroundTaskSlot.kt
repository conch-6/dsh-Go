package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks

/** The controller's one task resource. All mutations use its existing ownership monitor. */
internal class BackgroundTaskSlot<D : Any>(private val lock: Any) {
    class TaskResource<D : Any> internal constructor(val owner: PhoneTasks.Owner, val driver: D) {
        internal var sealed = false
        internal fun matches(other: PhoneTasks.Owner) =
            owner.taskId == other.taskId && owner.lifecycle == other.lifecycle
    }

    @Volatile private var resource: TaskResource<D>? = null
    // Readable under keepGuard without acquiring the outer ownership monitor in reverse order.
    val occupied: Boolean get() = resource != null

    fun find(owner: PhoneTasks.Owner): TaskResource<D>? = synchronized(lock) {
        resource?.takeIf { !it.sealed && it.matches(owner) }
    }

    /** create only constructs an unused driver; it must not connect or perform platform I/O. */
    fun acquire(owner: PhoneTasks.Owner, current: () -> Boolean, create: () -> D): TaskResource<D>? = synchronized(lock) {
        if (!owner.active || !current()) return null
        resource?.let { return it.takeIf { !it.sealed && it.matches(owner) } }
        TaskResource(owner, create()).also { resource = it }
    }

    fun current(expected: TaskResource<D>): Boolean = synchronized(lock) {
        resource === expected && !expected.sealed
    }

    fun cleanupCandidate(): TaskResource<D>? = synchronized(lock) { resource?.takeIf { it.sealed } }

    /** Cleanup does not require an active Owner; cancellation is why cleanup is often needed. */
    fun seal(taskId: Long? = null): TaskResource<D>? = synchronized(lock) {
        resource?.takeIf { taskId == null || it.owner.taskId == taskId }?.also { it.sealed = true }
    }

    /** Called only after this exact driver's strict release succeeded outside the monitor. */
    fun complete(expected: TaskResource<D>): Boolean = synchronized(lock) {
        if (resource !== expected) false
        else { check(expected.sealed); resource = null; true }
    }
}
