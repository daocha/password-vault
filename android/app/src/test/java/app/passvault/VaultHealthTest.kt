package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

class VaultHealthTest {
    /** Shared with iOS (FeatureChecks.swift strengthVectors) so both apps rate the same password the same way. */
    private val vectors = listOf(
        "" to 0, "123456" to 0, "password" to 0, "Password123!" to 0, "P@ssw0rd" to 0, "!monkey" to 0, "qwertyuiop" to 0, "woaini1314" to 0,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" to 0, "abcdefgh" to 0, "Ab1!" to 0, "zebra" to 0,
        "correcthorse" to 2, "k#9Lq!2v" to 2, "k#9Lq!2vX@" to 3, "Tr0ub4dor&3" to 3,
        "correct horse battery staple" to 4, "x7#Qm2!vLp9@Zr4^" to 4, "密码安全很重要" to 1, "我的密码很长而且很安全哦" to 3,
    )
    @Test fun strengthVectors() {
        val wrong = vectors.filter { (password, expected) -> PasswordStrength.score(password) != expected }.map { (p, e) -> "\"$p\" expected $e got ${PasswordStrength.score(p)} (${"%.1f".format(PasswordStrength.bits(p))} bits)" }
        assertTrue(wrong.joinToString("\n"), wrong.isEmpty())
    }
    @Test fun iosEmbedsTheSameWordList() {
        val swift = java.io.File("../../ios/Sources/VaultCore/CommonPasswords.swift")
        if (!swift.exists()) return // Android-only checkout
        val words = Regex("\"\"\"\\n(.*?)\\n\\s*\"\"\"", RegexOption.DOT_MATCHES_ALL).find(swift.readText())!!.groupValues[1].lines().map { it.trim() }.filter { it.isNotEmpty() }.toSet()
        assertEquals(PasswordStrength.common, words)
    }
    private fun login(name: String, password: String, website: String = "", updatedAt: String = Instant.now().toString(), history: List<PasswordChange> = emptyList()) =
        VaultRecord(name = name, website = website, updatedAt = updatedAt, fields = listOf(VaultField(kind = FieldKind.username, label = "Username", value = "me"), VaultField(kind = FieldKind.password, label = "Password", value = password, history = history)))
    @Test fun reportFindsEachKindOfProblem() {
        val today = LocalDate.of(2026, 10, 25)
        val strong = "x7#Qm2!vLp9@Zr4^"
        val a = login("Mail", strong); val b = login("Shop", strong); val c = login("Forum", "123456")
        val old = login("Old site", "Kf8#pW2!zQ7mVx", updatedAt = "2024-01-01T00:00:00Z")
        val changed = login("Changed", "Hn5\$tR9@kL2wQe", updatedAt = "2024-01-01T00:00:00Z", history = listOf(PasswordChange("before", Instant.parse("2026-06-01T00:00:00Z").epochSecond)))
        val github = login("GitHub", "Zp4!mQ8#rT2vWy", website = "https://github.com/login")
        val spotify = login("Spotify", "Yc3@nB7!kD5xLs")
        val spotifyCode = TotpAccount(Totp.decodeBase32("JBSWY3DPEHPK3PXP"), issuer = "Spotify", account = "me").record()
        val expiring = VaultRecord(name = "Passport", type = RecordType.note, fields = defaultFields(RecordType.note), expires = "2026-11-01")
        val seed = VaultRecord(name = "Wallet", type = RecordType.seed, fields = listOf(VaultField(kind = FieldKind.password, label = SEED_LABEL, value = "123456")))
        val report = VaultHealth.check(listOf(a, b, c, old, changed, github, spotify, spotifyCode, expiring, seed), today)
        assertEquals(listOf(setOf("Mail", "Shop")), report.reused.map { g -> g.map { it.record.name }.toSet() })
        assertEquals(listOf("Forum"), report.weak.map { it.first.record.name })
        assertEquals(listOf("Old site"), report.old.map { it.first.record.name })
        assertEquals(listOf("Passport"), report.expiring.map { it.name })
        assertEquals(listOf("GitHub"), report.noTwoFactor.map { it.name })
        assertEquals(7, report.checked)
        // 7 passwords: Mail, Shop and Forum count nothing, Old site half.
        assertEquals(Math.round(100.0 * (7 - 3 - 0.5) / 7).toInt(), report.score)
    }
    @Test fun sameRecordTwiceIsNotReuseAndEmptyVaultHasNoScore() {
        val record = VaultRecord(name = "Two", fields = listOf(VaultField(kind = FieldKind.password, label = "Password", value = "Kf8#pW2!zQ7mVx"), VaultField(kind = FieldKind.password, label = "PIN", value = "Kf8#pW2!zQ7mVx")))
        assertTrue(VaultHealth.check(listOf(record)).reused.isEmpty())
        assertNull(VaultHealth.check(emptyList()).score)
        assertEquals(100, VaultHealth.check(listOf(record)).score)
    }
    @Test fun passwordKeeperSetDateIsUsed() {
        val record = login("Keeper", "Kf8#pW2!zQ7mVx").copy(legacy = mapOf("passwordSetDate" to "1500000000"))
        assertEquals(LocalDate.of(2017, 7, 14), VaultHealth.passwordSetOn(CheckedPassword(record, record.fields[1])))
    }
    @Test fun totpCoversOnlyTheMatchingAccount() {
        fun spotify(username: String) = login("Spotify", "Kf8#pW2!zQ7mVx", "https://spotify.com")
            .copy(fields = listOf(VaultField(kind = FieldKind.username, label = "Username", value = username), VaultField(kind = FieldKind.password, label = "Password", value = "Kf8#pW2!zQ7mVx")))
        val me = spotify("me@example.com"); val other = spotify("other@example.com")
        val code = TotpAccount(Totp.decodeBase32("JBSWY3DPEHPK3PXP"), issuer = "Spotify", account = " ME@example.com ").record()
        assertEquals(listOf(other.id), VaultHealth.check(listOf(me, other, code)).noTwoFactor.map { it.id })
        val unnamed = code.copy(fields = TotpAccount(Totp.decodeBase32("JBSWY3DPEHPK3PXP"), issuer = "Spotify").record().fields)
        assertEquals(2, VaultHealth.check(listOf(me, other, unnamed)).noTwoFactor.size)
    }
    @Test fun onlyRealPasswordsAreChecked() {
        val r = VaultRecord(name = "Imported", fields = listOf(VaultField(kind = FieldKind.password, label = "Password", value = "x7#Qm2!vLp9@Zr4^"),
            VaultField(kind = FieldKind.password, label = "PIN", value = "1234"), VaultField(kind = FieldKind.password, label = "One-time password", value = "steam://AB"),
            VaultField(kind = FieldKind.password, label = "Old password", value = "123456"), VaultField(kind = FieldKind.question, label = "Security question", value = "Paris")))
        assertEquals(listOf("Password", "Old password"), VaultHealth.passwordFields(r).map { it.label })
        assertEquals(listOf("Old password"), VaultHealth.check(listOf(r)).weak.map { it.first.field.label })
    }
}
