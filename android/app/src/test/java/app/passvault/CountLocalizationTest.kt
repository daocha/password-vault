package app.passvault

import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test

/** The same 2-visible / 10-total regression examples checked by iOS's security runner. */
class CountLocalizationTest {
    @Test fun chineseEntryAndSeedCountsKeepVisibleAndTotalInTheRightOrder() {
        for ((language, entries, seeds) in listOf(
            Triple("values-b+zh+Hans", "共 10 个条目，显示 2 个", "共 10 条助记词，显示 2 条"),
            Triple("values-b+zh+Hant", "共 10 個項目，顯示 2 個", "共 10 組助記詞，顯示 2 組"),
        )) {
            val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
                .parse(File("src/main/res/$language/strings_main.xml"))
            fun formatted(name: String): String {
                val strings = document.getElementsByTagName("string")
                val template = (0 until strings.length).map { strings.item(it) }
                    .first { it.attributes.getNamedItem("name").nodeValue == name }.textContent
                return String.format(Locale.ROOT, template, 2, 10)
            }
            assertEquals(language, entries, formatted("main_count_of_entries"))
            assertEquals(language, seeds, formatted("main_count_of_seeds"))
        }
    }
}
