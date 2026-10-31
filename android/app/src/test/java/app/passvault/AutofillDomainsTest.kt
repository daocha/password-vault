package app.passvault

import org.junit.Assert.*
import org.junit.Test

class AutofillDomainsTest {
    @Test fun privateHostingTenantsAreDifferentSites() {
        for (suffix in listOf("github.io", "pages.dev", "gitlab.io", "appspot.com", "blogspot.com", "s3.amazonaws.com")) {
            assertEquals("victim.$suffix", AutofillMatch.baseDomain("victim.$suffix"))
            assertFalse(suffix, AutofillDomains.sameSite("https://victim.$suffix", "attacker.$suffix"))
            assertTrue(suffix, AutofillDomains.sameSite("https://login.victim.$suffix", "victim.$suffix"))
        }
    }

    @Test fun followsPublicSuffixWildcardAndExceptionRules() {
        assertEquals("bbc.co.uk", AutofillMatch.baseDomain("www.bbc.co.uk"))
        assertNull(AutofillMatch.baseDomain("co.uk"))
        assertNull(AutofillMatch.baseDomain("github.io"))
        assertNull(AutofillMatch.baseDomain("foo.ck")) // *.ck
        assertEquals("bar.foo.ck", AutofillMatch.baseDomain("bar.foo.ck"))
        assertEquals("www.ck", AutofillMatch.baseDomain("login.www.ck")) // !www.ck
        assertNull(AutofillMatch.baseDomain("ward.kawasaki.jp")) // *.kawasaki.jp
        assertEquals("city.kawasaki.jp", AutofillMatch.baseDomain("www.city.kawasaki.jp"))
        assertEquals("example.unknown-tld", AutofillMatch.baseDomain("login.example.unknown-tld")) // implicit *
        assertNotNull(AutofillMatch.baseDomain("example.ᬩᬮᬶ.id")) // Valid PSL rule outside Java's original Unicode tables.
    }

    @Test fun ipAddressesAreComparedAsCompleteLiterals() {
        assertFalse(AutofillDomains.sameSite("https://10.0.0.1", "192.168.0.1"))
        assertTrue(AutofillDomains.sameSite("https://10.0.0.1:443/login", "10.0.0.1"))
        assertFalse(AutofillDomains.sameSite("https://[2001:db8::1]/", "2001:db8::2"))
        assertTrue(AutofillDomains.sameSite("https://[2001:db8::1]/", "2001:db8::1"))
        for (ambiguous in listOf("127.1", "0177.0.0.1", "2130706433", "0x7f000001", "0x7f.0.0.1", "1.2.3.0x4"))
            assertNull(ambiguous, AutofillDomains.host(ambiguous))
    }

    @Test fun canonicalizesOrdinaryInternationalNamesWithoutCollapsingDistinctSites() {
        assertTrue(AutofillDomains.sameSite("https://bücher.de/login", "xn--bcher-kva.de"))
        assertTrue(AutofillDomains.sameSite("https://www.Example.COM./", "example.com"))
        assertFalse(AutofillDomains.sameSite("https://faß.de", "fass.de"))
        assertFalse(AutofillDomains.sameSite("https://xn--fa-hia.de", "fass.de"))
        assertFalse(AutofillDomains.sameSite("https://apple.com", "аpple.com")) // Cyrillic 'a'
    }

    @Test fun refusesAmbiguousOrMalformedOrigins() {
        for (bad in listOf("https://bank.com@evil.com", "https://evil.com\\@bank.com", "javascript://bank.com", "https://bank.com:bad", "https://bank.com:99999", "https://bank.com:", "https://bank..com", "https://bank.com..", "https://bank.com%2eevil.com", "https://bank.com\nevil.com"))
            assertNull(bad, AutofillDomains.host(bad))
    }
}
