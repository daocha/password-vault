package app.passvault

import org.junit.Assert.*
import org.junit.Test

/** Exercises the packaged suffix resource with Android's IDN implementation, as well as the JVM unit coverage. */
class AutofillSecurityInstrumentedTest {
    @Test fun bundledSuffixListKeepsTenantsSeparateOnAndroid() {
        for (suffix in listOf("github.io", "pages.dev", "appspot.com", "s3.amazonaws.com")) {
            assertEquals("victim.$suffix", AutofillMatch.baseDomain("login.victim.$suffix"))
            assertFalse(AutofillDomains.sameSite("victim.$suffix", "attacker.$suffix"))
        }
        assertNull(AutofillMatch.baseDomain("ward.kawasaki.jp"))
        assertEquals("city.kawasaki.jp", AutofillMatch.baseDomain("www.city.kawasaki.jp"))
        assertNotNull(AutofillMatch.baseDomain("example.ᬩᬮᬶ.id"))
    }

    @Test fun androidNormalizationRefusesDistinctAndAmbiguousOrigins() {
        assertTrue(AutofillDomains.sameSite("https://bücher.de/login", "xn--bcher-kva.de"))
        assertFalse(AutofillDomains.sameSite("faß.de", "fass.de"))
        assertFalse(AutofillDomains.sameSite("10.0.0.1", "192.168.0.1"))
        assertNull(AutofillDomains.host("https://bank.com@evil.com"))
        assertNull(AutofillOrigin.resolve(listOf("victim.github.io", "attacker.github.io")))
        assertNull(AutofillOrigin.resolve(listOf("bank.com", null)))
    }
}
