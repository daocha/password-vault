package app.passvault

import org.junit.Assert.*
import org.junit.Test

/** Framing and codes (pure JVM). Encryption needs libsodium and runs in the instrumented tests. */
class TransferTest {
    @Test fun codesAreTwelveUnambiguousCharacters() {
        repeat(200) { val c = Transfer.newCode(); assertEquals(12, c.length); assertTrue(c.all { it in Transfer.CODE_ALPHABET }) }
        assertFalse(Transfer.CODE_ALPHABET.any { it in "01ILO" })
        assertEquals("7K4P-92XM-QD3F", Transfer.display("7K4P92XMQD3F"))
        assertEquals("7K4P92XMQD3F", Transfer.canonical(" 7k4p-92xm qd3f "))
        // Typing keeps letters and digits only; the dashes are shown, not stored.
        assertEquals("FM96", Transfer.typing("fm96")); assertEquals(listOf(4), Transfer.typingBreaks("FM96")); assertEquals(listOf(4, 8), Transfer.typingBreaks("FM962C3DE4FG"))
        assertEquals("7K4P92XMQD3F", Transfer.typing("7K4P-92XM-QD3F-EXTRA")); assertEquals(emptyList<Int>(), Transfer.typingBreaks("FM9"))
        for (bad in listOf("7K4P92XMQD3", "7K4P92XMQD3FF", "7K4P92XMQD30", "OK4P92XMQD3F")) assertThrows(bad, IllegalArgumentException::class.java) { Transfer.canonical(bad) }
    }
    @Test fun deflateRoundTripAndLimits() {
        val json = Records.encode(List(300) { VaultRecord(name = "Entry $it", website = "https://example$it.test") })
        val packed = Transfer.deflate(json)
        assertTrue("compresses well", packed.size * 3 < json.size)
        assertArrayEquals(json, Transfer.inflate(packed, Records.MAX_BYTES))
        assertThrows(IllegalArgumentException::class.java) { Transfer.inflate(packed, 100) }
        assertThrows(IllegalArgumentException::class.java) { Transfer.inflate(packed.copyOf(packed.size / 2), Records.MAX_BYTES) }
        assertThrows(IllegalArgumentException::class.java) { Transfer.inflate(byteArrayOf(-1, -1, -1, -1), Records.MAX_BYTES) }
    }
    @Test fun framesReassembleInAnyOrderWithRepeats() {
        val data = ByteArray(2345) { (it * 7).toByte() }
        val sender = TransferFrames.Sender(data, "AB12"); val frames = (0 until 5).map(sender::frame)
        assertEquals(5, sender.count); assertTrue(frames.all { it.startsWith("PVX2:AB12:5:2345:") && it.length < 700 })
        val collector = TransferFrames.Collector()
        for (f in frames.reversed() + frames) collector.add(f)
        assertTrue(collector.complete); assertArrayEquals(data, collector.result())
        val partial = TransferFrames.Collector()
        assertTrue(partial.add(frames[2])); assertFalse("repeat", partial.add(frames[2]))
        assertFalse(partial.add("otpauth://totp/x")); assertFalse(partial.add("PVX2:AB12:5:9999:1:AAAA")); assertFalse(partial.add("PVX2:AB12:5:2345:1:%%%"))
        assertFalse("short chunk", partial.add("PVX2:AB12:5:2345:1:AAAA"))
        assertEquals(1, partial.received); assertEquals(5, partial.total); assertNull(partial.result())
        // A frame from a newer transfer starts over.
        assertTrue(partial.add(TransferFrames.Sender(ByteArray(10), "ZZ99").frame(0))); assertTrue(partial.complete); assertArrayEquals(ByteArray(10), partial.result())
    }
    @Test fun missedFramesAreReplacedByAnyLaterOnes() {
        val data = ByteArray(141 * TransferFrames.CHUNK - 123) { (it * 31 + 5).toByte() }
        val sender = TransferFrames.Sender(data, "K7QD"); val random = java.util.Random(3)
        repeat(20) {
            // The camera reads only a third of what it is shown; 141 chunks then mixes, as on screen.
            val collector = TransferFrames.Collector(); var shown = 0; var read = 0
            while (!collector.complete) { val f = sender.frame(shown++); if (random.nextInt(3) == 0) { read++; collector.add(f) } }
            assertArrayEquals(data, collector.result())
            assertTrue("read $read frames for 141 chunks", read <= 141 + 12)
        }
        // Mixes alone do it too, e.g. a receiver started late.
        val late = TransferFrames.Collector(); var seed = 1000
        while (!late.complete) late.add(sender.frame(seed++))
        assertArrayEquals(data, late.result()); assertTrue(seed - 1000 <= 141 + 12)
    }
    @Test fun mixesMatchIos() {
        // The same values are checked in ios/Sources/SecurityChecks; both must pick the same chunks for a seed.
        assertArrayEquals(longArrayOf(0b11010), TransferFrames.mix(5, 5))
        assertEquals(listOf("3c1eba8b4dccc148", "d07a9d82d4f4bbaf", "1651"), TransferFrames.mix(1000, 141).map { java.lang.Long.toUnsignedString(it, 16) })
    }
    @Test fun readsTheFirstVersionsLoop() {
        val data = ByteArray(2345) { (it * 7).toByte() }
        val frames = data.toList().chunked(TransferFrames.CHUNK).mapIndexed { i, c -> "PVX1:AB12:${i + 1}/5:" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(c.toByteArray()) }
        val collector = TransferFrames.Collector()
        for (f in frames.reversed() + frames) collector.add(f)
        assertTrue(collector.complete); assertArrayEquals(data, collector.result())
        assertFalse(TransferFrames.Collector().add("PVX1:AB12:9/5:AAAA"))
    }
    @Test fun largestTransferReassemblesQuickly() {
        val data = ByteArray(TransferFrames.CHUNK * TransferFrames.MAX_FRAMES) { it.toByte() }
        val sender = TransferFrames.Sender(data); val collector = TransferFrames.Collector()
        val started = System.nanoTime()
        // Every 100th chunk is missed and made up from mixes, the costliest case for the receiver.
        for (i in 0 until sender.count) if (i % 100 != 0) collector.add(sender.frame(i))
        var seed = sender.count; while (!collector.complete) collector.add(sender.frame(seed++))
        assertArrayEquals(data, collector.result()); assertTrue("fast enough", System.nanoTime() - started < 20_000_000_000L)
    }
}
