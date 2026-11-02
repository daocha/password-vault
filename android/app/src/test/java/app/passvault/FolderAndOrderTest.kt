package app.passvault

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class FolderAndOrderTest {
    @Test fun largeVaultFilteringKeeps501EntriesAndNeverSearchesSecrets() {
        val records = (0 until 501).map { index ->
            VaultRecord(id = "entry-$index", name = "Entry $index", group = if (index < 25) "Small folder" else "Other",
                fields = listOf(VaultField(kind = FieldKind.username, label = "Username", value = "person-$index"),
                    VaultField(kind = FieldKind.password, label = "Password", value = "never-search-this-secret")))
        }
        assertEquals(501, records.count { it.matches("") })
        assertEquals(25, records.count { it.group == "Small folder" && it.matches("") })
        assertEquals(listOf("entry-500"), records.filter { it.matches("person-500") }.map { it.id })
        assertFalse(records.any { it.matches("never-search-this-secret") })
    }
    @Test fun sharedBackupKeepsImportedFoldersAndTotpOrder() {
        val imported = Records.decode(File("../../fixtures/list-parity/records.json").readBytes())
        assertEquals(listOf("Personal", "Work"), VaultFolders.names(imported))
        val restored = Records.decode(Records.encode(imported))
        assertEquals(listOf("Gamma", "Alpha", "Beta", "Aardvark"), restored.filter { it.type == RecordType.totp }.sortedWith(TotpOrder.comparator).map { it.name })
        assertEquals(listOf("Work login", "Work card", "Work note"), restored.filter { it.type.tab == RecordType.login && it.group.trim() == "Work" }.map { it.name })
        assertTrue(restored.all { it.legacy["vendor"] == "preserved" })
    }
}
