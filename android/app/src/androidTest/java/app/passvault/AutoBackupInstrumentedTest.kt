package app.passvault

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.security.KeyStore

/** Automatic backups on the real engine (Keystore, libsodium): no password after set-up, ordinary backup files, and keys that expire. */
class AutoBackupInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(context.noBackupFilesDir, "passvault")
    private val password = "A lengthy test passphrase 1!"
    private val decoyPassword = "A separate decoy passphrase 2!"
    private lateinit var storage: ProtectedStorage
    private lateinit var engine: VaultEngine

    private fun wipe() {
        directory.deleteRecursively()
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.let { ks -> java.util.Collections.list(ks.aliases()).filter { it.startsWith("passvault-") }.forEach(ks::deleteEntry) }
    }
    private fun attempts() = JSONObject(String(storage.readState()!!)).getInt("attempts")
    private fun ready(result: VaultEngine.Automatic) = result as? VaultEngine.Automatic.Ready ?: error("expected a backup, got $result")

    @Before fun setUp() { wipe(); storage = ProtectedStorage(context); engine = VaultEngine(storage) }
    @After fun tearDown() { wipe() }

    @Test fun backupsNeedNoPasswordAfterSetUpAndOpenWithTheAppPassword() {
        engine.create(password); engine.save(listOf(VaultRecord(name = "Bank")))
        // Setting up checks the password as a counted attempt.
        assertThrows(AuthenticationFailure::class.java) { engine.sealAutoBackupKey("wrong password") }
        assertEquals(1, attempts()); assertEquals(9, engine.remainingAttempts())
        val sealed = engine.sealAutoBackupKey(password)
        assertEquals(0, attempts()); assertEquals(10, engine.remainingAttempts())

        val first = ready(engine.exportAutomatic(sealed, lastDigest = null))
        assertFalse(first.export.csv); assertFalse(first.export.decoy)
        assertEquals(listOf("Bank"), VaultCrypto.importBackup(first.export.bytes, password).map { it.name })
        assertThrows(AuthenticationFailure::class.java) { VaultCrypto.importBackup(first.export.bytes, "wrong password") }
        // Nothing changed: no new backup unless asked for.
        assertSame(VaultEngine.Automatic.Unchanged, engine.exportAutomatic(sealed, first.digest))
        val forced = ready(engine.exportAutomatic(sealed, first.digest, force = true))
        assertFalse("each file has its own nonce", forced.export.bytes.contentEquals(first.export.bytes))
        assertArrayEquals(first.digest, forced.digest)

        engine.save(listOf(VaultRecord(name = "Bank"), VaultRecord(name = "Mail")))
        val second = ready(engine.exportAutomatic(sealed, first.digest))
        assertFalse(second.digest.contentEquals(first.digest))
        assertEquals(listOf("Bank", "Mail"), VaultCrypto.importBackup(second.export.bytes, password).map { it.name }.sorted())
        // The stored key is not the backup key itself: it opens only with this vault's data key.
        assertFalse(String(sealed, Charsets.ISO_8859_1).contains(String(second.export.bytes.copyOfRange(0, 32), Charsets.ISO_8859_1)))

        engine.lock()
        assertThrows(IllegalStateException::class.java) { engine.exportAutomatic(sealed, null) }
        engine.unlock(password)
        assertTrue(engine.exportAutomatic(sealed, null) is VaultEngine.Automatic.Ready)
    }

    @Test fun aNewPasswordOrAnotherVaultCannotUseTheKey() {
        engine.create(password); engine.save(listOf(VaultRecord(name = "Bank")))
        val sealed = engine.sealAutoBackupKey(password)
        engine.createDecoy(password, decoyPassword)
        engine.lock(); engine.unlock(decoyPassword); engine.save(listOf(VaultRecord(name = "Shopping")))
        // The decoy cannot write the real vault's backups.
        assertSame(VaultEngine.Automatic.KeyGone, engine.exportAutomatic(sealed, null))
        val decoySealed = engine.sealAutoBackupKey(decoyPassword)
        val decoy = ready(engine.exportAutomatic(decoySealed, null))
        assertTrue(decoy.export.decoy)
        assertEquals(listOf("Shopping"), VaultCrypto.importBackup(decoy.export.bytes, decoyPassword).map { it.name })
        engine.lock(); engine.unlock(password)
        assertSame(VaultEngine.Automatic.KeyGone, engine.exportAutomatic(decoySealed, null))
        // After a password change the old key no longer works, so backups never keep the old password.
        val next = "Another lengthy passphrase 3!"
        engine.changePassword(password, next)
        assertSame(VaultEngine.Automatic.KeyGone, engine.exportAutomatic(sealed, null))
        val renewed = ready(engine.exportAutomatic(engine.sealAutoBackupKey(next), null))
        assertEquals(listOf("Bank"), VaultCrypto.importBackup(renewed.export.bytes, next).map { it.name })
    }

    @Test fun eachBackupIsANewFileInTheFolder() {
        val folder = File(context.cacheDir, "auto-backup-folder-test").apply { deleteRecursively(); mkdirs() }
        try {
            val start = java.time.Instant.parse("2026-11-19T10:00:00Z")
            val target = AutoBackupFiles.folder(context.contentResolver, android.net.Uri.fromFile(folder))
            val first = AutoBackupFiles.writeToFolder(target, byteArrayOf(1), start)
            val second = AutoBackupFiles.writeToFolder(target, byteArrayOf(2, 3), start.plusSeconds(60))
            assertEquals(setOf(first, second), folder.list()!!.toSet())
            assertArrayEquals(byteArrayOf(1), File(folder, first).readBytes())
            assertArrayEquals(byteArrayOf(2, 3), File(folder, second).readBytes())
            // Two in the same second: the second one's name ends _2, and neither replaces the other.
            val third = AutoBackupFiles.writeToFolder(target, byteArrayOf(4), start.plusSeconds(60))
            assertEquals(second.removeSuffix(".pvault") + "_2.pvault", third)
            assertArrayEquals(byteArrayOf(2, 3), File(folder, second).readBytes())
            File(folder, "holiday.jpg").writeBytes(byteArrayOf(9))
            val uri = android.net.Uri.fromFile(folder)
            assertEquals(listOf(third, second, first), AutoBackupFiles.newest(AutoBackupFiles.list(context.contentResolver, uri)))
            // A folder PassVault cannot read any more is an error, not an empty list.
            folder.deleteRecursively()
            assertThrows(SecurityException::class.java) { AutoBackupFiles.list(context.contentResolver, uri) }
            // A picked folder without a persisted grant is refused before it is read.
            val tree = android.provider.DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", "primary:PassVaultNoGrant")
            assertThrows(SecurityException::class.java) { AutoBackupFiles.list(context.contentResolver, tree) }
        } finally { folder.deleteRecursively() }
    }
}
