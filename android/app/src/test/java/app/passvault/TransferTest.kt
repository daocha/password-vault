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
        val frames = TransferFrames.frames(data, "AB12")
        assertEquals(5, frames.size); assertTrue(frames.all { it.startsWith("PVX1:AB12:") && it.length < 700 })
        val collector = TransferFrames.Collector()
        for (f in frames.reversed() + frames) collector.add(f)
        assertTrue(collector.complete); assertArrayEquals(data, collector.result())
        val partial = TransferFrames.Collector()
        assertTrue(partial.add(frames[2])); assertFalse("repeat", partial.add(frames[2]))
        assertFalse(partial.add("otpauth://totp/x")); assertFalse(partial.add("PVX1:AB12:9/5:AAAA")); assertFalse(partial.add("PVX1:AB12:1/5:%%%"))
        assertEquals(1, partial.received); assertEquals(5, partial.total); assertNull(partial.result())
        // A frame from a newer transfer starts over.
        assertTrue(partial.add(TransferFrames.frames(ByteArray(10), "ZZ99")[0])); assertTrue(partial.complete); assertArrayEquals(ByteArray(10), partial.result())
    }
    @Test fun largestTransferReassemblesQuickly() {
        val data = ByteArray(TransferFrames.CHUNK * TransferFrames.MAX_FRAMES) { it.toByte() }
        val collector = TransferFrames.Collector(); TransferFrames.frames(data).forEach { collector.add(it) }
        val started = System.nanoTime(); val result = collector.result()
        assertArrayEquals(data, result); assertTrue("linear join", System.nanoTime() - started < 2_000_000_000L)
    }
}
