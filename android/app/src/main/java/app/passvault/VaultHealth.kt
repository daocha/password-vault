package app.passvault

import java.time.Instant
import java.time.LocalDate
import kotlin.math.ln

/**
 * Offline password-strength estimate: no breach lookup and no network. Common passwords (and the same with leetspeak, or digits and
 * symbols tacked on) score 0. Otherwise the estimate is length × log2(character pool), where a character that only repeats the previous
 * one or continues an alphabetical, numerical or keyboard-row run counts half, and each further one in the same run a tenth. iOS
 * implements the same rules and word list.
 */
object PasswordStrength {
    /** 0 very weak, 1 weak, 2 fair, 3 strong, 4 very strong. */
    fun score(password: String): Int {
        if (password.isEmpty() || isCommon(password)) return 0
        val bits = bits(password)
        val score = when { bits < 28 -> 0; bits < 36 -> 1; bits < 60 -> 2; bits < 80 -> 3; else -> 4 }
        return if (password.codePointCount(0, password.length) < 8) minOf(score, 1) else score
    }
    fun bits(password: String): Double {
        val chars = password.codePoints().toArray()
        var pool = 0
        if (chars.any { it in 'a'.code..'z'.code }) pool += 26
        if (chars.any { it in 'A'.code..'Z'.code }) pool += 26
        if (chars.any { it in '0'.code..'9'.code }) pool += 10
        if (chars.any { it in 0x20..0x7E && !Character.isLetterOrDigit(it) }) pool += 33
        if (chars.any { it > 0x7E }) pool += 100
        var length = 0.0; var run = 0
        for (i in chars.indices) {
            run = if (i > 0 && continues(chars[i - 1], chars[i])) run + 1 else 0
            length += when (run) { 0 -> 1.0; 1 -> 0.5; else -> 0.1 }
        }
        return length * ln(pool.toDouble()) / ln(2.0)
    }
    private val rows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890")
    private fun continues(previous: Int, current: Int): Boolean {
        val a = Character.toLowerCase(previous); val b = Character.toLowerCase(current)
        if (a == b) return true
        if (Character.isLetterOrDigit(a) && Character.isLetterOrDigit(b) && a < 0x80 && b < 0x80 && Math.abs(a - b) == 1) return true
        return rows.any { row -> val i = row.indexOf(a.toChar()); i >= 0 && (row.getOrNull(i + 1)?.code == b || row.getOrNull(i - 1)?.code == b) }
    }
    val common: Set<String> by lazy {
        PasswordStrength::class.java.getResourceAsStream("/common-passwords.txt")!!.bufferedReader().readLines().map { it.trim() }.filter { it.isNotEmpty() }.toSet()
    }
    private val leet = mapOf('@' to 'a', '4' to 'a', '0' to 'o', '1' to 'i', '!' to 'i', '3' to 'e', '5' to 's', '$' to 's', '7' to 't', '+' to 't')
    fun isCommon(password: String): Boolean {
        val lower = password.lowercase()
        // Digits and symbols around a word ("Password123!", "!monkey") do not make it a new password.
        val core = lower.trim { !it.isLetter() }
        val candidates = listOf(lower, core, lower.map { leet[it] ?: it }.joinToString(""), core.map { leet[it] ?: it }.joinToString(""))
        return candidates.any { it.length >= 3 && it in common }
    }
}

/** One password field of one login record, the unit every check reports on. */
data class CheckedPassword(val record: VaultRecord, val field: VaultField)
class HealthReport(
    /** Passwords used by more than one entry, one list per shared value. */
    val reused: List<List<CheckedPassword>>,
    val weak: List<Pair<CheckedPassword, Int>>,
    /** Passwords not changed for over [VaultHealth.OLD_DAYS] days, with when they were set. */
    val old: List<Pair<CheckedPassword, LocalDate>>,
    val expiring: List<VaultRecord>,
    /** Logins for well-known services that have no authenticator record here. Advice only: the service may use another 2FA method. */
    val noTwoFactor: List<VaultRecord>,
    val checked: Int,
) {
    /** 0–100: each checked password counts fully when fine, half when only old, nothing when reused or weak. Null with nothing to check. */
    val score: Int? get() {
        if (checked == 0) return null
        val bad = (reused.flatten() + weak.map { it.first }).map { it.field.id to it.record.id }.toSet()
        val aged = old.map { it.first.field.id to it.first.record.id }.toSet() - bad
        return Math.round(100.0 * (checked - bad.size - aged.size * 0.5) / checked).toInt()
    }
    val problemCount get() = reused.sumOf { it.size } + weak.size + old.size + expiring.size
}

object VaultHealth {
    const val OLD_DAYS = 365L
    fun check(records: List<VaultRecord>, today: LocalDate = LocalDate.now()): HealthReport {
        val passwords = records.filter { it.type == RecordType.login }.flatMap { r -> r.fields.filter { it.kind == FieldKind.password && it.value.isNotEmpty() }.map { CheckedPassword(r, it) } }
        val reused = passwords.groupBy { it.field.value }.values.filter { group -> group.map { it.record.id }.distinct().size > 1 }
            .sortedByDescending { it.size }
        val weak = passwords.map { it to PasswordStrength.score(it.field.value) }.filter { it.second <= 1 }.sortedBy { it.second }
        val cutoff = today.minusDays(OLD_DAYS)
        val old = passwords.mapNotNull { p -> passwordSetOn(p)?.takeIf { it.isBefore(cutoff) }?.let { p to it } }.sortedBy { it.second }
        val expiring = records.filter { it.expiryState(today) == ExpiryState.expired || it.expiryState(today) == ExpiryState.soon }.sortedBy { it.expiryDate }
        val covered = records.filter { it.type == RecordType.totp }.mapNotNull { t -> findBrand(t.totp?.issuer.orEmpty(), t.name)?.id }.toSet()
        val noTwoFactor = records.filter { it.type == RecordType.login && it.fields.any { f -> f.kind == FieldKind.password && f.value.isNotEmpty() } }
            .filter { r -> findBrand(r.website, r.name)?.let { it.id !in covered } == true }.sortedBy { it.name.lowercase() }
        return HealthReport(reused, weak, old, expiring, noTwoFactor, passwords.size)
    }
    /**
     * When the current value was set: the newest history entry (the moment the previous value was replaced), else Password Keeper's
     * `passwordSetDate`, else the record's last change, which is only an upper bound for records edited without changing the password.
     */
    fun passwordSetOn(p: CheckedPassword): LocalDate? {
        val epoch = p.field.history.maxOfOrNull { it.changedAtEpochSeconds }?.takeIf { it > 0 }
            ?: p.record.legacy["passwordSetDate"]?.toLongOrNull()?.takeIf { it > 0 }?.let { if (it > 100_000_000_000L) it / 1000 else it }
        val instant = epoch?.let(Instant::ofEpochSecond) ?: runCatching { Instant.parse(p.record.updatedAt) }.getOrNull() ?: return null
        return instant.atZone(java.time.ZoneId.systemDefault()).toLocalDate()
    }
}
