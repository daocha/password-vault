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
    @Test fun reportedCases() {
        assertEquals("schwab", id("schwab.com")); assertEquals("schwab", id("Charles Schwab")); assertEquals("schwab", id("", "Charles Schwab Bank"))
        assertEquals("abc", id("abchina.com")); assertEquals("abc", id("中國農業銀行")); assertEquals("abc", id("", "中国农业银行信用卡"))
        assertEquals("amazon", id("Amazon.com")); assertEquals("amazon", id("amazon.com")); assertEquals("microsoft", id("Microsoft"))
        assertEquals("linkedin", id("https://www.linkedin.com/login"))
    }
    @Test fun matchesCryptoExchangesAndWallets() {
        assertEquals("binance", id("binance.com")); assertEquals("coinbase", id("Coinbase")); assertEquals("okx", id("www.okx.com"))
        assertEquals("bitget", id("Bitget")); assertEquals("gateio", id("gate.io")); assertEquals("htx", id("Huobi")); assertEquals("cryptocom", id("Crypto.com"))
        assertEquals("maicoin", id("max.maicoin.com")); assertEquals("hashkey", id("hashkey.com"))
        assertEquals("trustwallet", id("Trust Wallet")); assertEquals("phantom", id("phantom.app")); assertEquals("metamask", id("MetaMask")); assertEquals("ledger", id("Ledger Live"))
        assertEquals("coinbasewallet", id("wallet.coinbase.com")); assertNull(id("Max")); assertNull(id("Edge"))
    }
    @Test fun reportedWalletCases() {
        assertEquals("metamask", id("Metamask Wallet")); assertEquals("metamask", id("MetaMask")); assertEquals("phantom", id("Phantom")); assertEquals("phantom", id("Phantom Wallet"))
        assertEquals("phantom", id("HTTPS://WWW.Phantom.APP/x")); assertEquals("cathaybk", id("國泰世華銀行")); assertEquals("bybit", id("Bybit Exchange"))
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
