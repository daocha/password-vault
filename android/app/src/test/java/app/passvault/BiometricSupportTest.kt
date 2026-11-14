package app.passvault

import androidx.biometric.BiometricManager
import app.passvault.BiometricSupport.Availability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BiometricSupportTest {
    @Test fun biometricManagerAnswersMapToAvailability() {
        assertEquals(Availability.AVAILABLE, BiometricSupport.fromStatus(BiometricManager.BIOMETRIC_SUCCESS))
        assertEquals(Availability.NOT_ENROLLED, BiometricSupport.fromStatus(BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED))
        // A tablet with only face unlock (Class 2) reports no strong hardware: biometric unlock can never be turned on there.
        assertEquals(Availability.UNSUPPORTED, BiometricSupport.fromStatus(BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE))
        assertEquals(Availability.UNSUPPORTED, BiometricSupport.fromStatus(BiometricManager.BIOMETRIC_ERROR_UNSUPPORTED))
        assertEquals(Availability.UNAVAILABLE, BiometricSupport.fromStatus(BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE))
        assertEquals(Availability.UNAVAILABLE, BiometricSupport.fromStatus(BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED))
        assertEquals(Availability.UNAVAILABLE, BiometricSupport.fromStatus(BiometricManager.BIOMETRIC_STATUS_UNKNOWN))
    }

    @Test fun theSwitchCanAlwaysTurnBiometricsOffButOnlyOnWhenReady() {
        assertTrue(BiometricSupport.canToggle(Availability.AVAILABLE, enabled = false))
        for (availability in listOf(Availability.NOT_ENROLLED, Availability.UNSUPPORTED, Availability.UNAVAILABLE)) {
            assertFalse("$availability cannot turn biometrics on", BiometricSupport.canToggle(availability, enabled = false))
            assertTrue("$availability can still turn biometrics off", BiometricSupport.canToggle(availability, enabled = true))
        }
    }
}
