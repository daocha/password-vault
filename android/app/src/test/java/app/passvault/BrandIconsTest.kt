package app.passvault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BrandIconsTest {
    private fun id(website: String, name: String = "") = findBrand(website, name)?.id
    @Test fun matchesByNameOrDomain() {
        assertEquals("spotify", id("Spotify"))
        assertEquals("spotify", id("spotify.com"))
        assertEquals("spotify", id("https://open.spotify.com/track/1?x=y"))
        assertEquals("spotify", id("", "SPOTIFY"))
        assertEquals("github", id("www.github.com"))
        assertEquals("google", id("mail.google.com"))
        assertEquals("google", id("Gmail"))
        assertEquals("x", id("twitter.com"))
    }
    @Test fun matchesBanksAndSynology() {
        assertEquals("synology", id("Synology"))
        assertEquals("schwab", id("Charles Schwab"))
        assertEquals("schwab", id("client.schwab.com"))
        assertEquals("chase", id("chase.com"))
        assertEquals("wellsfargo", id("Wells Fargo"))
        assertEquals("citi", id("online.citibank.com.hk"))
        assertEquals("ctbc", id("中國信託"))
        assertEquals("cmb", id("招商银行"))
        assertEquals("icbc", id("www.icbc.com.cn"))
        assertEquals("hangseng", id("hangseng.com"))
        assertEquals("hsbc", id("www.hsbc.com.hk"))
    }
    @Test fun genericMarksDoNotMatchByName() { assertNull(id("ABC")); assertNull(id("Post")); assertNull(id("Key")) }
    @Test fun websiteWinsOverName() = assertEquals("github", id("github.com", "Spotify"))
    @Test fun doesNotOverMatch() {
        assertNull(id("Spotify family plan"))
        assertNull(id("notspotify.com"))
        assertNull(id("spotify.com.evil.example"))
        assertNull(id("Apple pie recipes"))
        assertNull(id("", ""))
    }
}
