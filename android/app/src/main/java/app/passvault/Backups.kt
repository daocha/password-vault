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
    /** Entries added or edited after [snapshotAt] (all of them when the saved backup's cutoff is unknown). Deleted entries cannot be counted. */
    fun changedSince(records: List<VaultRecord>, snapshotAt: Instant?): Int =
        if (snapshotAt == null) records.size else records.count { r -> runCatching { Instant.parse(r.updatedAt) }.getOrNull()?.isAfter(snapshotAt) ?: true }
    /**
     * A reminder is due when reminders are on, the vault has entries, it is not snoozed, and either there has never been a backup or the
     * last one is at least an interval old and something changed since.
     */
    fun due(records: List<VaultRecord>, lastBackup: Instant?, interval: BackupInterval, snoozedUntil: Instant?, now: Instant = Instant.now(), snapshotAt: Instant? = lastBackup): Boolean {
        val days = interval.days ?: return false
        if (records.isEmpty() || (snoozedUntil != null && now.isBefore(snoozedUntil))) return false
        if (lastBackup == null) return true
        return Duration.between(lastBackup, now) >= Duration.ofDays(days) && changedSince(records, snapshotAt) > 0
    }
}

/**
 * One export owns its bytes and the metadata for those exact records, even while another export is prepared or the vault locks.
 * [weakPassword]: the password protecting an encrypted backup is easy to guess, which matters most once the file is out of the phone.
 */
class VaultExport private constructor(val bytes: ByteArray, val csv: Boolean, val decoy: Boolean, val fileKeys: Set<String>, val weakPassword: Boolean,
    private val instance: Long, private val snapshotAt: Instant) {
    fun clear() { bytes.fill(0) }
    /**
     * Called only after a successful write. CSV is not a backup, and the destination history belongs to the source vault: not recorded
     * when that vault was removed or replaced while the file was being written (see [BackupStatus.instance]).
     */
    fun recordBackup(prefs: SharedPreferences, savedAt: Instant) {
        if (!csv) BackupStatus(prefs, if (decoy) "decoy." else "").record(savedAt, fileKeys, instance, snapshotAt)
    }

    companion object {
        /**
         * Called under the engine's lock; the encoder and the fingerprints see the same record snapshot. [instance]: the source vault's
         * [BackupStatus.instance], read under the same lock. [snapshotAt] is captured before encoding or opening a picker: edits made
         * while the file is being prepared or saved must still count as unbacked changes.
         */
        fun prepare(records: List<VaultRecord>, csv: Boolean, decoy: Boolean, encode: (List<VaultRecord>) -> ByteArray, weakPassword: Boolean = false,
            instance: (decoy: Boolean) -> Long = { 0L }, snapshotAt: Instant = Instant.now()): VaultExport {
            val snapshot = records.toList()
            val keys = if (csv) emptySet() else FileKeys.of(snapshot).map { FileKeys.fingerprint(it.ageIdentity!!) }.toSet()
            val sourceInstance = instance(decoy)
            return VaultExport(encode(snapshot), csv, decoy, keys, weakPassword && !csv, sourceInstance, snapshotAt)
        }
    }
}

/**
 * When the last encrypted backup was saved, its key fingerprints and reminder settings, kept in ordinary preferences (no secrets).
 * [prefix] keeps each vault's history apart (the decoy vault has its own).
 */
class BackupStatus(private val prefs: SharedPreferences, private val prefix: String = "") {
    /** Written only by [record], with the key coverage of the same backup. */
    val lastBackup: Instant?
        get() = prefs.getLong(prefix + "lastBackupAt", 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli)
    /**
     * The saved backup's record cutoff. A backup saved before cutoffs were recorded uses its completion time, as reminders always did:
     * counting every entry as unbacked would show every upgraded vault "N entries to back up" for its whole content.
     */
    val snapshotAt: Instant?
        get() = prefs.getLong(prefix + "backupSnapshotAt", 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli) ?: lastBackup
    var interval: BackupInterval
        get() = runCatching { BackupInterval.valueOf(prefs.getString(prefix + "backupReminder", null) ?: "") }.getOrDefault(BackupInterval.month)
        set(value) { prefs.edit().putString(prefix + "backupReminder", value.name).apply() }
    var snoozedUntil: Instant?
        get() = prefs.getLong(prefix + "backupSnoozeUntil", 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli)
        set(value) { prefs.edit().putLong(prefix + "backupSnoozeUntil", value?.toEpochMilli() ?: 0L).apply() }
    /** Fingerprints of the file-encryption keys the last encrypted backup contained (see [FileKeys.fingerprint]); null before tracking. */
    val fileKeys: Set<String>?
        get() = prefs.getStringSet(prefix + "backupFileKeys", null)?.toSet()
    /**
     * Which vault this history belongs to: [clear] moves it on when the vault is removed or replaced, so a backup of the old vault that
     * finishes afterwards is not credited to the new one.
     */
    val instance: Long get() = prefs.getLong(prefix + "backupInstance", 0L)
    /** Completion time, record cutoff and key coverage belong to the same backup. Ignored when [instance] has moved on. */
    fun record(savedAt: Instant, keys: Set<String>, instance: Long = this.instance, snapshotAt: Instant = savedAt) {
        if (instance != this.instance) return
        prefs.edit().putLong(prefix + "lastBackupAt", savedAt.toEpochMilli()).putLong(prefix + "backupSnapshotAt", snapshotAt.toEpochMilli()).putStringSet(prefix + "backupFileKeys", keys)
            .remove(prefix + "backupSnoozeUntil").apply()
    }
    /** Forgets this vault's backup history: the time, key coverage and reminder settings (when the vault is removed or replaced). */
    fun clear() {
        prefs.edit().putLong(prefix + "backupInstance", instance + 1).remove(prefix + "lastBackupAt").remove(prefix + "backupSnapshotAt").remove(prefix + "backupFileKeys").remove(prefix + "backupReminder").remove(prefix + "backupSnoozeUntil").apply()
    }
    fun snooze(now: Instant = Instant.now()) { snoozedUntil = now.plus(Duration.ofDays(BackupReminder.SNOOZE_DAYS)) }
}
