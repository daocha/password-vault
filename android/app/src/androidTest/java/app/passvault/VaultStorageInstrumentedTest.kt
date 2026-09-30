package app.passvault

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator

/**
 * Runs the real engine against the real Android Keystore on an emulator or device with a screen lock set
 * (`adb shell locksettings set-pin 1234`). Uses the emulator-only "qa" variant, which allows software-backed keys.
 */
class VaultStorageInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(context.noBackupFilesDir, "passvault")
    private val password = "A lengthy test passphrase 1!"
    // Built from code points so the two spellings of "e with acute" stay visibly different in source.
    private val composed = "Caf" + 0xE9.toChar() + " pass phrase 1!"
    private val decomposed = "Cafe" + 0x301.toChar() + " pass phrase 1!"
    private lateinit var storage: ProtectedStorage
    private lateinit var engine: VaultEngine

    private fun keystore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun stateAliases() = java.util.Collections.list(keystore().aliases()).filter { it.startsWith("passvault-state") }
    private fun wipe() {
        directory.deleteRecursively()
        keystore().let { ks -> java.util.Collections.list(ks.aliases()).filter { it.startsWith("passvault-") }.forEach(ks::deleteEntry) }
    }
    private fun fresh() { storage = ProtectedStorage(context); engine = VaultEngine(storage) }
    private fun stateFile() = File(directory, "state")
    private fun generation() = StateFormat.generation(stateFile().readBytes())
    private fun blobs() = directory.listFiles().orEmpty().filter { it.name.endsWith(".vault") }
    private fun dataKey() = VaultEngine::class.java.getDeclaredField("key").apply { isAccessible = true }.get(engine) as ByteArray?
    private fun record(name: String) = VaultRecord(name = name)
    private fun attempts() = JSONObject(String(storage.readState()!!)).getInt("attempts")

    @Before fun setUp() { wipe(); fresh() }
    @After fun tearDown() { wipe() }

    @Test fun importReplacesByIdAndFullReplacementDeletesTheRest() {
        val a = record("a"); val b = record("b"); val c = record("c")
        engine.create(password); engine.save(listOf(a, b, c))
        val fewer = a.copy(name = "a2", fields = a.fields.drop(1)) // same id, one field deleted elsewhere
        val merged = engine.merge(listOf(fewer, record("d")))
        assertEquals(listOf("a2", "b", "c", "d"), merged.map { it.name }); assertEquals(a.id, merged[0].id); assertEquals(a.fields.size - 1, merged[0].fields.size)
        val replaced = engine.replaceAll(listOf(fewer))
        assertEquals(listOf(fewer), replaced)
    }

    @Test fun createUnlockAndWrongPasswordCountsOneAttempt() {
        engine.create(password); engine.save(listOf(record("one"))); engine.lock()
        assertThrows(AuthenticationFailure::class.java) { engine.unlock("Wrong password 1!") }
        assertEquals(9, engine.remainingAttempts())
        assertEquals(listOf("one"), engine.unlock(password).map { it.name })
        assertEquals(10, engine.remainingAttempts())
    }

    @Test fun everyStateWriteMovesToANewKeyAndOnlyOneKeyRemains() {
        engine.create(password); engine.lock()
        val first = generation()
        assertEquals(1, stateAliases().size)
        assertThrows(AuthenticationFailure::class.java) { engine.unlock("Wrong password 1!") }
        assertTrue(generation() > first); assertEquals(listOf("passvault-state-g${generation()}"), stateAliases())
        val afterFailure = generation()
        engine.unlock(password) // reserving the attempt moves to a new key once; clearing the counter afterwards does not need another
        assertEquals(afterFailure + 1, generation()); assertEquals(1, stateAliases().size)
        val afterUnlock = generation()
        engine.save(listOf(record("x")))
        assertTrue(generation() > afterUnlock); assertEquals(1, stateAliases().size)
    }

    @Test fun restoringAnEarlierStateFileCannotGiveBackFailedAttempts() {
        engine.create(password); engine.lock()
        val original = stateFile().readBytes() // attempts = 0
        repeat(3) { assertThrows(AuthenticationFailure::class.java) { engine.unlock("Wrong password 1!") } }
        assertEquals(7, engine.remainingAttempts())
        stateFile().writeBytes(original)
        fresh()
        assertThrows(IllegalStateException::class.java) { engine.exists() }
        assertThrows(IllegalStateException::class.java) { engine.unlock(password) }
    }

    @Test fun restoringStateAndVaultFilesTogetherIsAlsoRefused() {
        engine.create(password); engine.save(listOf(record("old"))); engine.lock()
        val snapshot = directory.listFiles().orEmpty().filter { it.isFile }.associate { it.name to it.readBytes() }
        engine.unlock(password); engine.save(listOf(record("new"))); engine.lock()
        directory.listFiles().orEmpty().forEach { it.delete() }
        snapshot.forEach { (name, bytes) -> File(directory, name).writeBytes(bytes) }
        fresh()
        assertThrows(IllegalStateException::class.java) { engine.unlock(password) }
    }

    @Test fun missingStateKeyFailsClosed() {
        engine.create(password); engine.lock()
        keystore().let { ks -> stateAliases().forEach(ks::deleteEntry) }
        fresh()
        assertThrows(IllegalStateException::class.java) { engine.exists() }
        assertThrows(IllegalStateException::class.java) { engine.create(password) }
    }

    @Test fun tenWrongAttemptsEraseEverythingIncludingKeys() {
        engine.create(password); engine.save(listOf(record("secret"))); engine.lock()
        repeat(9) { assertThrows(AuthenticationFailure::class.java) { engine.unlock("Wrong password 1!") } }
        assertThrows(IllegalStateException::class.java) { engine.unlock("Wrong password 1!") }
        assertTrue(stateAliases().isEmpty()); assertTrue(blobs().isEmpty())
        fresh()
        assertTrue(engine.isErased())
        assertThrows(IllegalStateException::class.java) { engine.unlock(password) }
        engine.resetErasedVault(); assertFalse(engine.exists())
        engine.create(password); assertEquals(1, stateAliases().size) // a new vault starts cleanly after a reset
    }

    @Test fun changingPasswordRotatesTheDataKeyAndReencryptsTheVault() {
        engine.create(password); engine.save(listOf(record("keep me")))
        val oldKey = dataKey()!!.copyOf(); val oldBlob = blobs().single()
        val oldBlobBytes = oldBlob.readBytes()
        val newPassword = "Another long passphrase 2@"
        engine.changePassword(password, newPassword)
        val newKey = dataKey()!!
        assertFalse(oldKey.contentEquals(newKey))
        val newBlob = blobs().single(); assertNotEquals(oldBlob.name, newBlob.name)
        assertFalse(oldBlobBytes.contentEquals(newBlob.readBytes()))
        // The old data key can no longer open the current vault file, and the new one can.
        assertThrows(AuthenticationFailure::class.java) { VaultCrypto.open(newBlob.readBytes(), oldKey, newBlob.nameWithoutExtension.toByteArray()) }
        VaultCrypto.open(newBlob.readBytes(), newKey, newBlob.nameWithoutExtension.toByteArray())
        engine.lock(); fresh()
        assertThrows(AuthenticationFailure::class.java) { engine.unlock(password) }
        assertEquals(listOf("keep me"), engine.unlock(newPassword).map { it.name })
        engine.save(listOf(record("keep me"), record("added"))); engine.lock(); fresh()
        assertEquals(2, engine.unlock(newPassword).size)
    }

    @Test fun changingPasswordWithWrongCurrentPasswordChangesNothing() {
        engine.create(password); engine.save(listOf(record("a")))
        val before = dataKey()!!.copyOf(); val blob = blobs().single().name
        assertThrows(AuthenticationFailure::class.java) { engine.changePassword("Wrong password 1!", "Another long passphrase 2@") }
        assertArrayEquals(before, dataKey()); assertEquals(blob, blobs().single().name)
        engine.lock(); fresh(); assertEquals(1, engine.unlock(password).size)
    }

    @Test fun anEarlierStateFileLayoutIsMigratedOnFirstUnlock() {
        engine.create(password); engine.save(listOf(record("legacy"))); engine.lock()
        val plain = storage.readState()!!
        // Recreate what a pre-ratchet install left behind: one fixed key and `iv | ciphertext`.
        val ks = keystore(); stateAliases().forEach(ks::deleteEntry)
        val spec = KeyGenParameterSpec.Builder("passvault-state-v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).setUnlockedDeviceRequired(true).build()
        val key = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(spec) }.generateKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key); updateAAD("PassVault/state/v1".toByteArray()) }
        stateFile().writeBytes(cipher.iv + cipher.doFinal(plain))
        assertEquals(0, generation())
        fresh()
        assertEquals(listOf("legacy"), engine.unlock(password).map { it.name })
        assertEquals(1, generation()); assertEquals(listOf("passvault-state-g1"), stateAliases()) // migrated, old key deleted
        engine.lock(); fresh(); assertEquals(1, engine.unlock(password).size)
    }

    @Test fun normalizedAndComposedFormsOfAPasswordOpenTheSameVault() {
        engine.create(decomposed); engine.lock()
        assertEquals(0, engine.unlock(composed).size); engine.lock()
        assertEquals(0, engine.unlock(decomposed).size)
    }

    @Test fun aVaultKeyedFromTheRawTypedTextIsAcceptedOnceAndRewrapped() {
        engine.create(password); engine.save(listOf(record("old install"))); val dataKey = dataKey()!!.copyOf(); engine.lock()
        // Re-wrap the data key the way versions before normalization did: Argon2id over the bytes exactly as typed.
        val state = JSONObject(String(storage.readState()!!)); val salt = Base64.getDecoder().decode(state.getString("salt")); val secret = Base64.getDecoder().decode(state.getString("secret"))
        val derived = VaultCrypto.passwordKey(decomposed, salt, legacyEncoding = true)
        val wrapping = VaultCrypto.deviceKey(derived, secret)
        state.put("wrapped", Base64.getEncoder().encodeToString(VaultCrypto.seal(dataKey, wrapping, "PassVault/key/v1".toByteArray())))
        storage.writeState(state.toString().toByteArray())
        fresh()
        assertThrows(AuthenticationFailure::class.java) { engine.unlock("Cafe pass phrase 1!") }
        assertEquals(9, engine.remainingAttempts())
        assertEquals(listOf("old install"), engine.unlock(decomposed).map { it.name })
        assertEquals(10, engine.remainingAttempts()) // the fallback cost one attempt, not two
        val rewrapped = JSONObject(String(storage.readState()!!))
        assertNotEquals(state.getString("salt"), rewrapped.getString("salt"))
        engine.lock(); assertEquals(1, engine.unlock("Café pass phrase 1!".let { composed }).size) // now keyed from the normalized text
    }

    @Test fun backupsUseTheStrongerProfileAndOldFilesStillOpen() {
        val records = listOf(record("exported"))
        val started = System.nanoTime()
        val backup = VaultCrypto.exportBackup(records, password)
        val exportMs = (System.nanoTime() - started) / 1_000_000
        assertTrue(VaultCrypto.isBackup(backup)); assertEquals("QVAULT02", String(backup, 0, 8))
        assertEquals(listOf("exported"), VaultCrypto.importBackup(backup, password).map { it.name })
        assertThrows(AuthenticationFailure::class.java) { VaultCrypto.importBackup(backup, "Wrong password 1!") }
        // Tampering with the authenticated cost fields makes the file undecryptable rather than cheaper.
        val weaker = backup.copyOf().also { it[11] = (it[11] - 1).toByte() }
        assertThrows(Exception::class.java) { VaultCrypto.importBackup(weaker, password) }
        // A QVAULT01 file made by an earlier version (64 MiB, 3 passes), including one keyed from non-normalized text.
        fun v1(pw: String, raw: Boolean): ByteArray {
            val salt = VaultCrypto.random(16); val header = "QVAULT01".toByteArray() + salt
            val key = VaultCrypto.passwordKey(pw, salt, KdfProfile.VAULT, raw)
            return header + VaultCrypto.seal(Records.encode(records), key, header)
        }
        assertEquals(1, VaultCrypto.importBackup(v1(password, false), password).size)
        assertEquals(1, VaultCrypto.importBackup(v1(decomposed, true), decomposed).size)
        assertEquals(1, VaultCrypto.importBackup(v1(decomposed, false), composed).size)
        println("QVAULT02 export took $exportMs ms")
    }

    @Test fun stateFromANewerVersionSaysToUpdateInsteadOfClaimingAMissingKey() {
        engine.create(password); engine.lock()
        stateFile().writeBytes("PVS3".toByteArray() + ByteArray(64) { 7 })
        fresh()
        val error = assertThrows(NewerVersionException::class.java) { engine.exists() }
        assertFalse(error.backup)
        assertThrows(NewerVersionException::class.java) { engine.unlock(password) }
        // The newer file is left exactly as found, so updating the app opens it.
        assertEquals("PVS3", String(stateFile().readBytes(), 0, 4))
    }

    @Test fun aNewerBackupIsReportedAsNewerNotAsWrongPassword() {
        val error = assertThrows(NewerVersionException::class.java) { VaultCrypto.importBackup("QVAULT03".toByteArray() + ByteArray(80), password) }
        assertTrue(error.backup)
    }
}
