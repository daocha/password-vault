package app.passvault

import org.junit.Assert.*
import org.junit.Test

class PasswordPolicyInstrumentedTest {
    @Test fun passwordGuessabilityRunsOnAndroid() {
        // zxcvbn reads its dictionaries from the APK; if it could not, guessable passwords would quietly pass on phones.
        assertTrue(PasswordPolicy.guesses("Summer2026!!") < PasswordPolicy.MIN_GUESSES_LOG10)
        assertEquals(R.string.app_pw_guessable, PasswordPolicy.problem("Password123!"))
        assertNull(PasswordPolicy.problem("Correct horse battery 1!"))
    }
}
