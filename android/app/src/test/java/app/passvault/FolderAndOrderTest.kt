package app.passvault

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class FolderAndOrderTest {
    @Test fun sharedBackupKeepsImportedFoldersAndTotpOrder() {
        val imported = Records.decode(File("../../fixtures/list-parity/records.json").readBytes())
        assertEquals(listOf("Personal", "Work"), VaultFolders.names(imported))
        val restored = Records.decode(Records.encode(imported))
        assertEquals(listOf("Gamma", "Alpha", "Beta", "Aardvark"), restored.filter { it.type == RecordType.totp }.sortedWith(TotpOrder.comparator).map { it.name })
        assertEquals(listOf("Work login", "Work card", "Work note"), restored.filter { it.type.tab == RecordType.login && it.group.trim() == "Work" }.map { it.name })
        assertTrue(restored.all { it.legacy["vendor"] == "preserved" })
    }
}
