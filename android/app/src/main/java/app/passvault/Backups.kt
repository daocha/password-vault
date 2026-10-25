package app.passvault

import android.content.SharedPreferences
import androidx.annotation.StringRes
import java.time.Duration
import java.time.Instant

/** How often to remind about an encrypted backup. */
enum class BackupInterval(val days: Long?, @StringRes val labelRes: Int) {
    off(null, R.string.backup_reminder_off), week(7, R.string.backup_reminder_week), twoWeeks(14, R.string.backup_reminder_two_weeks), month(30, R.string.backup_reminder_month)
}

object BackupReminder {
    const val SNOOZE_DAYS = 3L
    /** Entries added or edited after [lastBackup] (all of them before any backup). Deleted entries cannot be counted. */
    fun changedSince(records: List<VaultRecord>, lastBackup: Instant?): Int =
        if (lastBackup == null) records.size else records.count { r -> runCatching { Instant.parse(r.updatedAt) }.getOrNull()?.isAfter(lastBackup) ?: true }
    /**
     * A reminder is due when reminders are on, the vault has entries, it is not snoozed, and either there has never been a backup or the
     * last one is at least an interval old and something changed since.
     */
    fun due(records: List<VaultRecord>, lastBackup: Instant?, interval: BackupInterval, snoozedUntil: Instant?, now: Instant = Instant.now()): Boolean {
        val days = interval.days ?: return false
        if (records.isEmpty() || (snoozedUntil != null && now.isBefore(snoozedUntil))) return false
        if (lastBackup == null) return true
        return Duration.between(lastBackup, now) >= Duration.ofDays(days) && changedSince(records, lastBackup) > 0
    }
}

/**
 * When the last encrypted backup was saved and the reminder settings, kept in ordinary preferences (no secrets: only times and a choice).
 * [prefix] keeps each vault's history apart (the decoy vault has its own).
 */
class BackupStatus(private val prefs: SharedPreferences, private val prefix: String = "") {
    var lastBackup: Instant?
        get() = prefs.getLong(prefix + "lastBackupAt", 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli)
        set(value) { prefs.edit().putLong(prefix + "lastBackupAt", value?.toEpochMilli() ?: 0L).remove(prefix + "backupSnoozeUntil").apply() }
    var interval: BackupInterval
        get() = runCatching { BackupInterval.valueOf(prefs.getString(prefix + "backupReminder", null) ?: "") }.getOrDefault(BackupInterval.month)
        set(value) { prefs.edit().putString(prefix + "backupReminder", value.name).apply() }
    var snoozedUntil: Instant?
        get() = prefs.getLong(prefix + "backupSnoozeUntil", 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli)
        set(value) { prefs.edit().putLong(prefix + "backupSnoozeUntil", value?.toEpochMilli() ?: 0L).apply() }
    fun snooze(now: Instant = Instant.now()) { snoozedUntil = now.plus(Duration.ofDays(BackupReminder.SNOOZE_DAYS)) }
}
