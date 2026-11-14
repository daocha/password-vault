package app.passvault

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LockedRetryTest {
    @Test fun nothingToRetryBeforeAFailure() = assertFalse(LockedRetry().take())

    @Test fun aLockedDeviceIsRetriedOnce() {
        val retry = LockedRetry()
        retry.failed(DeviceLockedException())
        assertTrue(retry.take())
        assertFalse("taken once, then only a new refusal asks again", retry.take())
    }

    @Test fun otherFailuresAreNotRetried() {
        val retry = LockedRetry()
        retry.failed(IllegalStateException("Protected state is missing."))
        assertFalse(retry.take())
    }

    @Test fun aLaterOtherFailureReplacesTheRefusal() {
        val retry = LockedRetry()
        retry.failed(DeviceLockedException()); retry.failed(java.io.IOException("disk"))
        assertFalse(retry.take())
    }
}
