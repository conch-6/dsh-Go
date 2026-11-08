package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

/** The actual production classifier receives structured PM adapter facts; this is not a PM emulator. */
class SystemHandlersTest {
    private val browser = SystemHandler("browser.app", "browser.app.Link", 10123)

    @Test fun exactCandidateIsKnownIncludingNonAndroidOemPackages() {
        val oem = SystemHandler("vendor.settings", "vendor.settings.Wifi", 1000)
        assertEquals(SystemResolution.Known(oem), SystemHandlers.resolve(listOf(oem), oem, null, true))
        assertEquals(SystemResolution.Known(browser), SystemHandlers.resolve(listOf(browser), browser, null, true))
    }

    @Test fun outsideResolverRequiresActualChooserAndCannotServeExplicitAppOpen() {
        val outside = SystemHandler("vendor.selection", "vendor.selection.Pick", 1000)
        assertEquals(SystemResolution.Choice, SystemHandlers.resolve(listOf(browser), outside, null, true))
        assertNull(SystemHandlers.resolve(listOf(browser), outside, null, false))
    }

    @Test fun noResolverOrNoCandidatesIsNotUserChoice() {
        assertNull(SystemHandlers.resolve(listOf(browser), null, null, true))
        assertNull(SystemHandlers.resolve(emptyList(), browser, null, true))
        assertFalse(SystemHandlers.valid(emptyList(), null)) // Explicit chooser still needs candidates.
    }

    @Test fun invalidIdentityAndConflictingUidNeverTurnIntoChooser() {
        for (invalid in listOf(browser.copy(uid = -1), browser.copy(packageName = ""), browser.copy(component = ""))) {
            assertNull(SystemHandlers.resolve(listOf(invalid), invalid, null, true))
            assertNull(SystemHandlers.resolve(listOf(browser), invalid, null, true))
        }
        assertNull(SystemHandlers.resolve(listOf(browser), browser.copy(uid = 20123), null, true))
        assertNull(SystemHandlers.resolve(listOf(browser, browser.copy(uid = 20123)), browser, null, true))
    }

    @Test fun sharedUidDoesNotMergeDifferentPackagesAndPackageConstraintIsPreserved() {
        val other = browser.copy(packageName = "other.app", component = "other.app.Link")
        assertEquals(SystemResolution.Choice, SystemHandlers.resolve(listOf(browser), other, null, true))
        assertNull(SystemHandlers.resolve(listOf(browser), browser, "other.app", true))
        assertFalse(SystemHandlers.valid(listOf(browser, other), "browser.app"))
    }

}
