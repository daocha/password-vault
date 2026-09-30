package app.passvault

import java.nio.ByteBuffer
import java.text.Normalizer

/** Passwords are used as NFKC-normalized UTF-8, so the same typed text derives the same key on every keyboard and platform. */
object PasswordText {
    const val MAX_BYTES = 4096
    fun normalize(password: String): String = Normalizer.normalize(password, Normalizer.Form.NFKC)
    fun bytes(password: String): ByteArray = normalize(password).toByteArray(Charsets.UTF_8)
    /** UTF-8 exactly as typed: how versions before normalization keyed their data. Only a fallback to open that older data. */
    fun legacyBytes(password: String): ByteArray = password.toByteArray(Charsets.UTF_8)
    fun differs(password: String) = normalize(password) != password
}

/**
 * Data written by a newer PassVault than this one understands (a backup, or the protected local state). The UI shows an "update the app"
 * message for it instead of a generic failure. [backup] tells the two apart.
 */
class NewerVersionException(val backup: Boolean) : IllegalArgumentException(
    if (backup) "This backup was made by a newer version of PassVault. Update the app and try again." else "Your vault was saved by a newer version of PassVault. Update the app to open it.")

/** Argon2id cost. [memKiB] is stored in backup headers, so it is kept in KiB. */
class KdfProfile(val opsLimit: Long, val memKiB: Int) {
    val memBytes get() = memKiB.toLong() * 1024
    companion object {
        /** Local vault (also guarded by the device secret and attempt limit) and QVAULT01 backups. */
        val VAULT = KdfProfile(3, 64 * 1024)
        /** QVAULT02 backups: portable and attackable offline with no attempt limit, so each guess is made costlier. */
        val BACKUP = KdfProfile(4, 256 * 1024)
    }
}

/**
 * Portable encrypted backup header (the whole header is authenticated as AAD).
 *
 *     QVAULT01: magic 8 | salt 16                                   (Argon2id 3 passes, 64 MiB)
 *     QVAULT02: magic 8 | u32be memKiB | u32be passes | salt 16
 */
object BackupFormat {
    private val magicV1 = "QVAULT01".toByteArray()
    private val magicV2 = "QVAULT02".toByteArray()
    const val V1_HEADER = 24
    const val V2_HEADER = 32
    /** A header cannot pick weaker or absurdly expensive parameters than these. */
    const val MIN_MEM_KIB = 64 * 1024; const val MAX_MEM_KIB = 1024 * 1024
    const val MIN_PASSES = 3; const val MAX_PASSES = 10
    class Header(val version: Int, val profile: KdfProfile, val salt: ByteArray, val size: Int)

    /** `QVAULT` followed by two digits above the versions this build reads: a backup from a newer PassVault. */
    fun isNewer(data: ByteArray): Boolean {
        if (data.size < 8 || !data.copyOfRange(0, 6).contentEquals("QVAULT".toByteArray())) return false
        val tens = data[6].toInt() - '0'.code; val ones = data[7].toInt() - '0'.code
        return tens in 0..9 && ones in 0..9 && tens * 10 + ones > 2
    }
    fun isBackup(data: ByteArray) = data.size >= 8 && data.copyOfRange(0, 8).let { it.contentEquals(magicV1) || it.contentEquals(magicV2) }
    fun header(profile: KdfProfile, salt: ByteArray): ByteArray {
        require(salt.size == 16)
        return ByteBuffer.allocate(V2_HEADER).put(magicV2).putInt(profile.memKiB).putInt(profile.opsLimit.toInt()).put(salt).array()
    }
    fun parse(data: ByteArray): Header {
        if (isNewer(data)) throw NewerVersionException(backup = true)
        require(data.size >= V1_HEADER) { "Unsupported or oversized encrypted backup." }
        val magic = data.copyOfRange(0, 8)
        return when {
            magic.contentEquals(magicV1) -> Header(1, KdfProfile.VAULT, data.copyOfRange(8, 24), V1_HEADER)
            magic.contentEquals(magicV2) -> {
                require(data.size >= V2_HEADER) { "Unsupported or oversized encrypted backup." }
                val buffer = ByteBuffer.wrap(data, 8, 8); val mem = buffer.int; val passes = buffer.int
                require(mem in MIN_MEM_KIB..MAX_MEM_KIB && passes in MIN_PASSES..MAX_PASSES) { "Unsupported encrypted backup settings." }
                Header(2, KdfProfile(passes.toLong(), mem), data.copyOfRange(16, 32), V2_HEADER)
            }
            else -> throw IllegalArgumentException("Unsupported or oversized encrypted backup.")
        }
    }
}
