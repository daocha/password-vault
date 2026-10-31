package app.passvault

import android.text.InputType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutofillTest {
    private val text = InputType.TYPE_CLASS_TEXT
    private val passwordInput = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
    private val emailInput = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
    private fun login(name: String, website: String = "", user: String = "me", pass: String = "secret") = VaultRecord(name = name, website = website,
        fields = listOf(VaultField(kind = FieldKind.username, label = "Username", value = user), VaultField(kind = FieldKind.password, label = "Password", value = pass)))

    @Test fun classifiesFieldsFromHintsInputTypesAndNames() {
        assertEquals(AutofillField.password, AutofillFields.classify(listOf("password"), 0, "", "", emptyList()))
        assertEquals(AutofillField.username, AutofillFields.classify(listOf("emailAddress"), 0, "", "", emptyList()))
        assertEquals(AutofillField.password, AutofillFields.classify(emptyList(), passwordInput, "", "", emptyList()))
        assertEquals(AutofillField.username, AutofillFields.classify(emptyList(), emailInput, "", "", emptyList()))
        assertEquals(AutofillField.password, AutofillFields.classify(emptyList(), 0, "password", "", listOf("pw")))
        assertEquals(AutofillField.username, AutofillFields.classify(emptyList(), 0, "text", "username", emptyList()))
        assertEquals(AutofillField.username, AutofillFields.classify(emptyList(), text, "", "", listOf("login_user_field")))
        assertEquals(AutofillField.other, AutofillFields.classify(emptyList(), text, "", "", listOf("first_name")))
    }

    @Test fun neverFillsOneTimeCodesOrNewPasswords() {
        assertNull(AutofillFields.classify(listOf("newPassword"), passwordInput, "", "", emptyList()))
        assertNull(AutofillFields.classify(emptyList(), 0, "password", "new-password", emptyList()))
        assertNull(AutofillFields.classify(emptyList(), 0, "text", "one-time-code", emptyList()))
        assertNull(AutofillFields.classify(emptyList(), passwordInput, "", "", listOf("confirm_password")))
        assertNull(AutofillFields.classify(emptyList(), text, "", "", listOf("otp_code")))
        assertNull(AutofillFields.classify(emptyList(), text, "", "", listOf("search_box")))
    }

    @Test fun picksTheLoginFields() {
        val u = AutofillField.username; val p = AutofillField.password; val o = AutofillField.other
        assertEquals(1 to 2, AutofillFields.pick(listOf(o, u, p)))
        // Without a marked username, the field just before the password.
        assertEquals(1 to 2, AutofillFields.pick(listOf(o, o, p)))
        assertEquals(null to 0, AutofillFields.pick(listOf(p, o)))
        // First step of a two-step sign-in.
        assertEquals(0 to null, AutofillFields.pick(listOf(u)))
        // Sign-up or change-password forms have two passwords.
        assertNull(AutofillFields.pick(listOf(u, p, p)))
        assertNull(AutofillFields.pick(listOf(o, o)))
    }

    @Test fun matchesSitesByRegistrableDomain() {
        assertEquals("google.com", AutofillMatch.baseDomain("accounts.google.com"))
        assertEquals("bbc.co.uk", AutofillMatch.baseDomain("www.bbc.co.uk"))
        val chrome = AutofillTarget("com.android.chrome", "accounts.google.com")
        assertTrue(AutofillMatch.suggests(login("Google", "https://www.google.com/"), chrome))
        assertTrue(AutofillMatch.suggests(login("Mail", "mail.google.com"), chrome))
        assertFalse(AutofillMatch.suggests(login("Lookalike", "google.com.evil.net"), chrome))
        assertFalse(AutofillMatch.suggests(login("Lookalike", "evil-google.com"), chrome))
        // On a site, the name alone is not enough.
        assertFalse(AutofillMatch.suggests(login("Google"), chrome))
    }

    @Test fun ignoresWebDomainsClaimedByOtherApps() {
        val app = AutofillTarget("com.example.notabrowser", "bank.com")
        assertEquals(null, app.site)
        assertFalse(AutofillMatch.suggests(login("Bank", "bank.com"), app))
    }

    @Test fun matchesAppsByPackageName() {
        val netflix = AutofillTarget("com.netflix.mediaclient", null)
        assertTrue(AutofillMatch.suggests(login("Movies", "https://www.netflix.com/login"), netflix))
        assertTrue(AutofillMatch.suggests(login("Netflix"), netflix))
        assertTrue(AutofillMatch.suggests(login("Work", "androidapp://com.netflix.mediaclient"), netflix))
        assertFalse(AutofillMatch.suggests(login("Spotify", "spotify.com"), netflix))
        // Generic package parts ("com", "android", "app") never match.
        assertFalse(AutofillMatch.suggests(login("App", "app.com"), AutofillTarget("com.example.app", null)))
        // A brand's other domains count: the Gmail app is Google's.
        assertTrue(AutofillMatch.suggests(login("Google account", "accounts.google.com"), AutofillTarget("com.google.android.gm", null)))
    }

    @Test fun matchesAppsByTheirName() {
        val dive = AutofillTarget("com.example.scuba", null)
        assertTrue(AutofillMatch.suggests(login("Dive+"), dive, "Dive+"))
        assertTrue(AutofillMatch.suggests(login("Diving log", "Dive+"), dive, "Dive+"))
        assertFalse(AutofillMatch.suggests(login("Dive+"), dive, "Dive Shop"))
        // On a site, only the address counts: a page cannot pass for an app by name.
        assertFalse(AutofillMatch.suggests(login("Dive+"), AutofillTarget("com.android.chrome", "evil.example"), "Dive+"))
    }

    @Test fun takesPhoneAndNumberFieldsForUsernames() {
        assertEquals(AutofillField.username, AutofillFields.classify(emptyList(), InputType.TYPE_CLASS_PHONE, "", "", listOf("et_input")))
        assertEquals(AutofillField.username, AutofillFields.classify(emptyList(), 0, "tel", "", emptyList()))
        assertEquals(AutofillField.password, AutofillFields.classify(emptyList(), InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD, "", "", emptyList()))
        assertEquals(AutofillField.other, AutofillFields.classify(emptyList(), InputType.TYPE_CLASS_NUMBER, "", "", listOf("et_input")))
        assertNull(AutofillFields.classify(emptyList(), InputType.TYPE_CLASS_NUMBER, "", "", listOf("sms_verification_code")))
    }

    @Test fun offersOnlyLoginsWithSomethingToFill() {
        val empty = VaultRecord(name = "Empty", fields = listOf(VaultField(kind = FieldKind.username, label = "Username"), VaultField(kind = FieldKind.password, label = "Password")))
        val note = VaultRecord(name = "Note", type = RecordType.note, fields = listOf(VaultField(kind = FieldKind.password, label = "Password", value = "x")))
        val ok = login("Site")
        assertEquals(listOf(ok), AutofillMatch.candidates(listOf(empty, note, ok)))
        assertEquals("me", AutofillMatch.username(ok)); assertEquals("secret", AutofillMatch.password(ok))
    }

    @Test fun displaysTheActualPackageAlongsideUnverifiedNamesAndDomains() {
        val spoof = AutofillTarget("com.attacker.utility", "accounts.google.com")
        assertNull(spoof.site) // Not treated as a browser for ranking.
        assertEquals("\u2066accounts.google.com\u2069 · Google (\u2066com.attacker.utility\u2069)", spoof.description("Google"))
        val hidden = spoof.description("Google\u202E\n\u2028\u200B" + "x".repeat(500))
        assertTrue(hidden.endsWith("(\u2066com.attacker.utility\u2069)")); assertFalse('\u202E' in hidden); assertFalse('\n' in hidden)
        assertFalse('\u2028' in hidden); assertFalse('\u200B' in hidden)
        assertTrue(hidden.length < 160)
    }

    @Test fun rejectsFieldsFromDifferentOrMalformedOrigins() {
        assertEquals(AutofillOrigin("login.example.com"), AutofillOrigin.resolve(listOf("login.example.com", "LOGIN.EXAMPLE.COM.")))
        assertEquals(AutofillOrigin(null), AutofillOrigin.resolve(listOf(null, null)))
        assertNull(AutofillOrigin.resolve(listOf("bank.com", "attacker.com")))
        assertNull(AutofillOrigin.resolve(listOf("login.example.com", "other.example.com")))
        assertNull(AutofillOrigin.resolve(listOf(null, "bank.com")))
        assertNull(AutofillOrigin.resolve(listOf("https://bank.com@attacker.com")))
    }
}
