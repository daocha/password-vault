package app.passvault

import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.lang.reflect.Proxy
import java.time.Instant
import java.time.ZoneOffset

class AutoBackupTest {
    @Test fun frequencyDefaultsToInstantAndBelongsToEachVault() {
        val prefs = preferences(); val settings = AutoBackupSettings(prefs); val decoy = AutoBackupSettings(prefs, "decoy.")
        assertEquals(AutoBackupFrequency.instant, settings.frequency)
        settings.frequency = AutoBackupFrequency.weekly
        assertEquals(AutoBackupFrequency.weekly, AutoBackupSettings(prefs).frequency)
        assertEquals(AutoBackupFrequency.instant, decoy.frequency)
        settings.turnOn("content://backups", "Backups", byteArrayOf(1))
        assertEquals(AutoBackupFrequency.weekly, settings.frequency)
        settings.clear()
        assertEquals(AutoBackupFrequency.instant, settings.frequency)
        prefs.edit().putString("autoBackupFrequency", "invalid").apply()
        assertEquals(AutoBackupFrequency.instant, settings.frequency)
    }

    @Test fun intervalsUseTheLastSuccessfulBackupWithAnInclusiveBoundary() {
        val last = Instant.parse("2026-11-19T10:00:00Z")
        for (frequency in AutoBackupFrequency.entries) {
            assertEquals(0L, frequency.remainingMillis(null, last))
            if (frequency == AutoBackupFrequency.instant) {
                assertEquals(0L, frequency.remainingMillis(last, last.minusSeconds(60)))
                continue
            }
            assertEquals(frequency.seconds * 1000, frequency.remainingMillis(last, last))
            assertEquals(1L, frequency.remainingMillis(last, last.plusSeconds(frequency.seconds).minusMillis(1)))
            assertEquals(0L, frequency.remainingMillis(last, last.plusSeconds(frequency.seconds)))
            assertEquals(0L, frequency.remainingMillis(last, last.plusSeconds(frequency.seconds + 1)))
            assertEquals((frequency.seconds + 60) * 1000, frequency.remainingMillis(last, last.minusSeconds(60)))
        }
        val settings = AutoBackupSettings(preferences())
        settings.frequency = AutoBackupFrequency.daily
        settings.succeeded(byteArrayOf(1), last)
        settings.failed(AutoBackupSettings.Problem.writeFailed)
        assertEquals(last, settings.lastAutomatic)
        assertEquals(86_399_000L, settings.remainingMillis(last.plusSeconds(1)))
    }

    @Test fun rapidBackupsKeepEveryVersionEvenWithinOneSecond() {
        val files = mutableMapOf<String, ByteArray>()
        val folder = AutoBackupFiles.Folder { name, bytes -> check(name !in files); files[name] = bytes }
        // A second no other test writes at: names written in this process count as taken.
        val at = Instant.parse("2026-11-19T10:00:07Z")
        val names = (0 until 20).map { AutoBackupFiles.writeToFolder(folder, byteArrayOf(it.toByte()), at) }
        assertEquals(20, files.size)
        assertEquals((0..19).toSet(), files.values.map { it.single().toInt() }.toSet())
        // Only the time names a backup; a second one within the same second ends _2, _3… and sorts after it.
        val stem = AutoBackupFiles.name(at).removeSuffix(".pvault")
        assertEquals(listOf("$stem.pvault") + (2..20).map { "${stem}_$it.pvault" }, names)
        assertEquals(names.reversed(), AutoBackupFiles.newest(names, 20))
    }

    @Test fun namesHoldOnlyTheTime() {
        val at = Instant.parse("2026-11-19T10:31:05Z")
        val taken = mutableSetOf<String>()
        repeat(3) { taken += AutoBackupFiles.uniqueName(at, ZoneOffset.UTC) { it in taken } }
        assertEquals(setOf("passvault_auto_2026-11-19_10_31_05.pvault", "passvault_auto_2026-11-19_10_31_05_2.pvault", "passvault_auto_2026-11-19_10_31_05_3.pvault"), taken)
        val folder = AutoBackupFiles.Folder { _, _ -> }
        val written = AutoBackupFiles.writeToFolder(folder, byteArrayOf(1), Instant.parse("2031-01-02T03:04:05Z"))
        assertTrue(written, Regex("passvault_auto_\\d{4}-\\d{2}-\\d{2}_\\d{2}_\\d{2}_\\d{2}\\.pvault").matches(written))
    }

    @Test fun settingsListsTheFiveNewestBackups() {
        val names = listOf(
            "holiday.jpg", "passvault_2026-11-01_09_00.pvault", "passvault_auto_2026-11-18_08_00_00.pvault", "passvault_auto_2026-11-19_10_31_05.pvault",
            "passvault_auto_2026-11-19_10_31_05_2.pvault", "passvault_auto_2026-11-17_23_59_59_0f8e2a4c-1b7d-4c2e-9a51-3d6f8b2e7c10.pvault",
            "passvault_auto_2026-11-19_09_00_00.pvault", "passvault_auto_2026-11-01_00_00_00.pvault", "passvault_auto_2026-11-19_09_00_00.pvault", "passvault_auto_notes.txt",
            "passvault_auto_2026-11-19_10_31_05_10.pvault", "passvault_auto_2026-11-19_10_31_05_9.pvault", "passvault_auto_2026-11-19_10_31_05 (1).pvault",
        )
        assertEquals(listOf(
            "passvault_auto_2026-11-19_10_31_05_10.pvault", "passvault_auto_2026-11-19_10_31_05_9.pvault", "passvault_auto_2026-11-19_10_31_05_2.pvault",
            "passvault_auto_2026-11-19_10_31_05 (1).pvault", "passvault_auto_2026-11-19_10_31_05.pvault",
        ), AutoBackupFiles.newest(names))
        assertEquals("passvault_auto_2026-11-17_23_59_59_0f8e2a4c-1b7d-4c2e-9a51-3d6f8b2e7c10.pvault", AutoBackupFiles.newest(names, 10)[7])
        assertEquals(emptyList<String>(), AutoBackupFiles.newest(listOf("holiday.jpg")))
    }

    @Test fun namesSortByAge() {
        val at = Instant.parse("2026-11-19T10:31:05Z")
        assertEquals("passvault_auto_2026-11-19_10_31_05.pvault", AutoBackupFiles.name(at, ZoneOffset.UTC))
        val names = (1..8).map { AutoBackupFiles.name(at.plusSeconds(it * 3600L), ZoneOffset.UTC) }
        assertEquals(names, names.shuffled().sorted())
    }

    @Test fun eachBackupIsANewFileAndNoneIsDeleted() {
        val files = sortedMapOf<String, ByteArray>("holiday.jpg" to byteArrayOf(9))
        val folder = AutoBackupFiles.Folder { name, bytes -> check(name !in files); files[name] = bytes }
        val start = Instant.parse("2026-11-19T10:00:00Z")
        val written = (0 until 30).map { AutoBackupFiles.writeToFolder(folder, byteArrayOf(it.toByte()), start.plusSeconds(it * 60L)) }
        // Every backup stays, so an entry deleted by mistake can be found in an older one; other files are left alone.
        assertEquals(written.toSet() + "holiday.jpg", files.keys)
        assertArrayEquals(byteArrayOf(29), files[written.last()])
    }

    @Test fun settingsArePerVaultAndClearedTogether() {
        val prefs = preferences()
        val main = AutoBackupSettings(prefs); val decoy = AutoBackupSettings(prefs, "decoy.")
        assertFalse(main.enabled)
        val uri = "content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FPassVault"
        main.turnOn(uri, "PassVault", byteArrayOf(1, 2, 3))
        assertTrue(main.enabled); assertFalse(decoy.enabled)
        assertEquals("PassVault", main.name)
        assertArrayEquals(byteArrayOf(1, 2, 3), main.sealedKey)
        assertNull(main.lastDigest); assertNull(main.problem)
        main.failed(AutoBackupSettings.Problem.noAccess)
        assertEquals(AutoBackupSettings.Problem.noAccess, main.problem)
        val at = Instant.ofEpochMilli(1_800_000_000_000)
        main.succeeded(byteArrayOf(7), at)
        assertNull("a success clears the problem", main.problem)
        assertArrayEquals(byteArrayOf(7), main.lastDigest); assertEquals(at, main.lastAutomatic)
        // A new folder or key starts over: the next backup is written even if nothing changed.
        main.turnOn(uri, "Other", byteArrayOf(4))
        assertNull(main.lastDigest)
        main.clear()
        assertFalse(main.enabled); assertNull(main.sealedKey); assertNull(main.lastAutomatic)
    }

    @Test fun aSingleFileFromATestBuildCountsAsOff() {
        val prefs = preferences()
        prefs.edit().putString("autoBackupMode", "file").putString("autoBackupUri", "content://drive/document/1").putString("autoBackupKey", "AQID").apply()
        assertFalse("one file replaced each time loses older backups; set up a folder", AutoBackupSettings(prefs).enabled)
    }

    @Test fun everyLanguageHasTheAutomaticBackupWording() {
        val english = File("src/main/res/values/strings_main.xml").readText()
        val keys = Regex("""<string name="(auto_backup_[a-z_]+)">""").findAll(english).map { it.groupValues[1] }.toList()
        assertTrue(keys.size >= 20)
        assertFalse("no single-file option", english.contains("auto_backup_choose_file"))
        for (dir in listOf("values-b+zh+Hans", "values-b+zh+Hant")) {
            val strings = File("src/main/res/$dir/strings_main.xml").readText()
            for (key in keys) assertTrue("$dir lacks $key", strings.contains("<string name=\"$key\">"))
        }
        assertFalse(File("src/main/AndroidManifest.xml").readText().contains("android.permission.INTERNET"))
    }

    /** Minimal SharedPreferences double: each editor applies its staged changes together, as the Android API does. */
    private fun preferences(): SharedPreferences {
        val values = java.util.Collections.synchronizedMap(mutableMapOf<String, Any?>())
        return Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getLong", "getString" -> values[args!![0]] ?: args[1]
                "edit" -> {
                    val staged = mutableMapOf<String, Any?>()
                    Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { editor, operation, input ->
                        when (operation.name) {
                            "putLong", "putString" -> { staged[input!![0] as String] = input[1]; editor }
                            "remove" -> { staged[input!![0] as String] = null; editor }
                            "apply" -> { values.putAll(staged); null }
                            else -> error("Unexpected preference edit: ${operation.name}")
                        }
                    }
                }
                else -> error("Unexpected preference read: ${method.name}")
            }
        } as SharedPreferences
    }
}
