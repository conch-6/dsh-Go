package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivilegedInputReasonTest {
    // InputManager answers false for a dispatch timeout too, after the event may have landed (#288).
    @Test fun anUnconfirmedInputIsNotCalledRejected() {
        val reason = Reasons.of("inputRejected")
        assertFalse(reason, reason.contains("拒绝"))
        assertTrue(reason, reason.contains("可能已发出"))
        assertTrue(reason, reason.contains("不要重复"))
    }

    // The generic message hides which step failed; a report can only name it through the detail (#342).
    @Test fun aGenericFailureNamesTheStepWhenItIsKnown() {
        assertTrue(Reasons.of("deviceUnavailable", "adb closed").endsWith("（adb closed）"))
        assertFalse(Reasons.of("deviceUnavailable", null).contains("（"))
        assertTrue(Reasons.withDetail("gate", "adb closed").endsWith("（adb closed）"))
    }
}
