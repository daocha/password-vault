package app.passvault

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

class BackupFormatTest {
    private val salt = ByteArray(16) { it.toByte() }
    private fun v2(mem: Int, passes: Int) = ByteBuffer.allocate(32).put("QVAULT02".toByteArray()).putInt(mem).putInt(passes).put(salt).array()
    private fun rejects(data: ByteArray) = assertThrows(IllegalArgumentException::class.java) { BackupFormat.parse(data) }

    @Test fun v2HeaderRoundTripsItsCost() {
        val header = BackupFormat.header(KdfProfile.BACKUP, salt)
        assertEquals(32, header.size)
        val parsed = BackupFormat.parse(header + ByteArray(40))
        assertEquals(2, parsed.version); assertEquals(32, parsed.size)
        assertEquals(KdfProfile.BACKUP.opsLimit, parsed.profile.opsLimit); assertEquals(256L * 1024 * 1024, parsed.profile.memBytes)
        assertArrayEquals(salt, parsed.salt)
    }
    @Test fun v1BackupsKeepTheirOriginalCostSoOldFilesStillOpen() {
        val parsed = BackupFormat.parse("QVAULT01".toByteArray() + salt + ByteArray(40))
        assertEquals(1, parsed.version); assertEquals(24, parsed.size)
        assertEquals(3L, parsed.profile.opsLimit); assertEquals(64L * 1024 * 1024, parsed.profile.memBytes)
        assertArrayEquals(salt, parsed.salt)
    }
    @Test fun newBackupsAreCostlierThanTheLocalVaultProfile() {
        assertTrue(KdfProfile.BACKUP.memKiB > KdfProfile.VAULT.memKiB); assertTrue(KdfProfile.BACKUP.opsLimit >= KdfProfile.VAULT.opsLimit)
    }
    @Test fun aHeaderCannotSelectWeakOrExcessiveCost() {
        BackupFormat.parse(v2(BackupFormat.MIN_MEM_KIB, BackupFormat.MIN_PASSES) + ByteArray(40))
        BackupFormat.parse(v2(BackupFormat.MAX_MEM_KIB, BackupFormat.MAX_PASSES) + ByteArray(40))
        rejects(v2(BackupFormat.MIN_MEM_KIB - 1, 4)); rejects(v2(BackupFormat.MAX_MEM_KIB + 1, 4))
        rejects(v2(256 * 1024, BackupFormat.MIN_PASSES - 1)); rejects(v2(256 * 1024, BackupFormat.MAX_PASSES + 1))
        rejects(v2(-1, 4)); rejects(v2(256 * 1024, -1)); rejects(v2(Int.MIN_VALUE, Int.MAX_VALUE))
    }
    @Test fun unknownOrTruncatedHeadersAreRejected() {
        rejects("QVAULT03".toByteArray() + salt + ByteArray(40)); rejects("PKB2".toByteArray()); rejects(ByteArray(0))
        rejects("QVAULT02".toByteArray() + ByteArray(10)); rejects("QVAULT01".toByteArray() + ByteArray(10))
    }
    @Test fun recognisesBothBackupVersionsOnly() {
        assertTrue(BackupFormat.isBackup("QVAULT01".toByteArray() + salt)); assertTrue(BackupFormat.isBackup(v2(256 * 1024, 4)))
        assertFalse(BackupFormat.isBackup("QVAULT03".toByteArray())); assertFalse(BackupFormat.isBackup(ByteArray(3)))
    }

    @Test fun passwordsAreNormalizedSoEveryKeyboardAgrees() {
        val composed = "caf" + 0xE9.toChar(); val decomposed = "cafe" + 0x301.toChar(); val fullWidth = "" + 0xFF21.toChar() + 0xFF42.toChar() + "c"
        assertNotEquals(composed, decomposed)
        assertArrayEquals(PasswordText.bytes(composed), PasswordText.bytes(decomposed))
        assertArrayEquals("Abc".toByteArray(), PasswordText.bytes(fullWidth))
        assertTrue(PasswordText.differs(decomposed)); assertFalse(PasswordText.differs(composed))
    }
    @Test fun asciiPasswordsAreUnchangedSoExistingVaultsKeepWorking() {
        val ascii = "A lengthy test passphrase 1!"
        assertFalse(PasswordText.differs(ascii)); assertArrayEquals(ascii.toByteArray(), PasswordText.bytes(ascii))
    }
    @Test fun legacyBytesAreTheTextAsTyped() {
        val decomposed = "cafe" + 0x301.toChar()
        assertArrayEquals(decomposed.toByteArray(Charsets.UTF_8), PasswordText.legacyBytes(decomposed))
        assertFalse(PasswordText.legacyBytes(decomposed).contentEquals(PasswordText.bytes(decomposed)))
    }
    @Test fun policyJudgesTheNormalizedPassword() {
        assertNull(PasswordPolicy.problem("Passw0rd!Passw0rd!"))
        // Twelve fullwidth-looking characters are still twelve after normalization; the composed and decomposed spellings score the same.
        val composedPw = "Caf" + 0xE9.toChar() + "-Caf" + 0xE9.toChar() + "1!"; val decomposedPw = "Cafe" + 0x301.toChar() + "-Cafe" + 0x301.toChar() + "1!"
        assertEquals(PasswordPolicy.problem(composedPw), PasswordPolicy.problem(decomposedPw))
        assertEquals(R.string.app_pw_min_length, PasswordPolicy.problem("Short1!"))
    }

    @Test fun stateHeaderCarriesTheGeneration() {
        val bytes = StateFormat.header(7) + ByteArray(12) + ByteArray(16)
        assertEquals(8, StateFormat.header(7).size); assertEquals(7, StateFormat.generation(bytes))
        assertFalse(StateFormat.aad(StateFormat.header(7)).contentEquals(StateFormat.aad(StateFormat.header(8))))
    }
    @Test fun earlierStateLayoutsAreTreatedAsGenerationZero() {
        assertEquals(0, StateFormat.generation(ByteArray(64) { 5 }))
        assertEquals(0, StateFormat.generation(StateFormat.header(3)))                     // too short to hold iv and tag
        assertEquals(0, StateFormat.generation(StateFormat.header(-1) + ByteArray(28)))   // negative generation is never valid
    }

    @Test fun aNewerBackupVersionIsRecognisedSoTheUserIsToldToUpdate() {
        val newer = "QVAULT03".toByteArray() + salt + ByteArray(40)
        assertTrue(BackupFormat.isNewer(newer)); assertTrue(BackupFormat.isNewer("QVAULT99".toByteArray()))
        val error = assertThrows(NewerVersionException::class.java) { BackupFormat.parse(newer) }
        assertTrue(error.backup)
        assertThrows(NewerVersionException::class.java) { BackupFormat.parse("QVAULT10".toByteArray()) } // even a truncated newer file
        // Versions this build reads, and things that are not backups at all, keep their own handling.
        assertFalse(BackupFormat.isNewer("QVAULT01".toByteArray() + salt)); assertFalse(BackupFormat.isNewer(v2(256 * 1024, 4)))
        assertFalse(BackupFormat.isNewer("QVAULT00".toByteArray())); assertFalse(BackupFormat.isNewer("QVAULTxx".toByteArray()))
        assertFalse(BackupFormat.isNewer("PKB2".toByteArray())); assertFalse(BackupFormat.isNewer("name,username,password\n".toByteArray())); assertFalse(BackupFormat.isNewer(ByteArray(0)))
        assertFalse(BackupFormat.isBackup(newer)) // the picker checks isNewer first so it never falls through to the CSV reader
    }
    @Test fun aNewerStateLayoutIsRecognisedButCurrentAndEarlierOnesAreNot() {
        assertTrue(StateFormat.isNewer("PVS3".toByteArray() + ByteArray(40))); assertTrue(StateFormat.isNewer("PVS9".toByteArray()))
        assertFalse(StateFormat.isNewer(StateFormat.header(1) + ByteArray(28))); assertFalse(StateFormat.isNewer("PVS1".toByteArray()))
        assertFalse(StateFormat.isNewer(ByteArray(64) { 5 })); assertFalse(StateFormat.isNewer("PVS".toByteArray()))
    }
}
