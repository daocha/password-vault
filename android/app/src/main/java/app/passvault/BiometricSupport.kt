package app.passvault

import android.content.Context
import androidx.biometric.BiometricManager

/** Whether this device can turn on biometric unlock, which needs a strong (Class 3) biometric such as most fingerprint sensors. */
internal object BiometricSupport {
    enum class Availability { AVAILABLE, NOT_ENROLLED, UNSUPPORTED, UNAVAILABLE }

    fun fromStatus(status: Int) = when (status) {
        BiometricManager.BIOMETRIC_SUCCESS -> Availability.AVAILABLE
        BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> Availability.NOT_ENROLLED
        // No sensor at all, or only weak ones (face unlock on many tablets): biometric unlock can never be turned on here.
        BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE, BiometricManager.BIOMETRIC_ERROR_UNSUPPORTED -> Availability.UNSUPPORTED
        else -> Availability.UNAVAILABLE // busy sensor, pending security update, unknown
    }

    fun availability(context: Context) = fromStatus(BiometricManager.from(context).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG))

    /** The switch can always turn biometric unlock off; turning it on needs a strong biometric ready to use. */
    fun canToggle(availability: Availability, enabled: Boolean) = enabled || availability == Availability.AVAILABLE
}
