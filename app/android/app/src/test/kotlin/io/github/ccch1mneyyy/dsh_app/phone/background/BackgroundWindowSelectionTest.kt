package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundWindowSelectionTest {
    private val target = "test.target"

    @Test fun aSingleMatchingApplicationWindowCanBeCompletelyScanned() {
        assertEquals(BackgroundTree.WindowSelection(0, true), BackgroundTree.selectApplicationWindow(listOf(target), target))
    }

    @Test fun aMissingRootBeforeTheTargetDoesNotHideTheTarget() {
        assertEquals(BackgroundTree.WindowSelection(1, false), BackgroundTree.selectApplicationWindow(listOf(null, target), target))
    }

    @Test fun aForeignApplicationBeforeTheTargetDoesNotHideTheTarget() {
        assertEquals(BackgroundTree.WindowSelection(1, false), BackgroundTree.selectApplicationWindow(listOf("test.caption", target), target))
    }

    @Test fun unscannedApplicationWindowsAfterTheTargetAlsoKeepImagesDisabled() {
        assertFalse(BackgroundTree.selectApplicationWindow(listOf(target, null), target)!!.complete)
        assertFalse(BackgroundTree.selectApplicationWindow(listOf(target, "test.caption"), target)!!.complete)
        assertFalse(BackgroundTree.selectApplicationWindow(listOf(target, target), target)!!.complete)
    }

    @Test fun theFirstExactPackageMatchKeepsWindowOrder() {
        assertEquals(BackgroundTree.WindowSelection(2, false), BackgroundTree.selectApplicationWindow(listOf("test.target.extra", null, target, target), target))
    }

    @Test fun noMatchingRootNeverSelectsAnotherPackage() {
        for (packages in listOf(emptyList(), listOf(null), listOf("test.caption"), listOf(null, "test.caption"))) {
            assertNull(BackgroundTree.selectApplicationWindow(packages, target))
        }
    }
}
