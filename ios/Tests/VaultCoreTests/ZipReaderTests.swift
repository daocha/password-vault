import XCTest
@testable import VaultCore

/// The same damaged archives as Android's ZipReaderTest, made from fixtures/exports/sample.1pux. Both readers must
/// accept or refuse each one with the same message.
final class ZipReaderTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func fixture(_ name: String) throws -> [UInt8] { Array(try Data(contentsOf: root.appendingPathComponent("fixtures/exports/\(name)"))) }

    private func u16(_ z: [UInt8], _ o: Int) -> Int { Int(z[o]) | Int(z[o + 1]) << 8 }
    private func u32(_ z: [UInt8], _ o: Int) -> Int { u16(z, o) | u16(z, o + 2) << 16 }
    private func put32(_ z: inout [UInt8], _ o: Int, _ v: Int) { for i in 0..<4 { z[o + i] = UInt8((v >> (8 * i)) & 0xFF) } }
    private func end(_ z: [UInt8]) -> Int { z.count - 22 } // sample.1pux has no comment
    /// Offset of export.data's central directory record.
    private func central(_ z: [UInt8]) -> Int {
        var pos = u32(z, end(z) + 16)
        while String(decoding: z[pos + 46..<pos + 46 + u16(z, pos + 28)], as: UTF8.self) != "export.data" {
            pos += 46 + u16(z, pos + 28) + u16(z, pos + 30) + u16(z, pos + 32)
        }
        return pos
    }
    private func assertRefused(_ z: [UInt8], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ZipReader.entry(z, name: "export.data"), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, message, file: file, line: line)
        }
    }

    func testReadsTheRecordsAndChecksTheirCrc() throws {
        let zip = try fixture("sample.1pux")
        let data = try XCTUnwrap(ZipReader.entry(zip, name: "export.data"))
        XCTAssertEqual(data.count, 1475)
        XCTAssertEqual(CRC32.checksum(data), u32(zip, central(zip) + 16))
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF43926) // the standard check value
        XCTAssertNil(try ZipReader.entry(zip, name: "missing"))
        XCTAssertNotNil(try ZipReader.entry(try fixture("skipped-attachment.1pux"), name: "export.data"))
    }

    func testASignatureInsideTheCommentIsNotTheEndRecord() throws {
        var zip = try fixture("sample.1pux")
        let comment = Array("PK\u{5}\u{6}".utf8) + Array(repeating: UInt8(ascii: "x"), count: 30)
        let at = end(zip); zip[at + 20] = UInt8(comment.count); zip += comment
        XCTAssertEqual(try ZipReader.entry(zip, name: "export.data")?.count, 1475)
        // A comment length that does not reach the end of the file leaves no valid end record.
        zip[at + 20] = UInt8(comment.count - 1)
        assertRefused(zip, ZipReader.damagedMessage)
    }

    func testWrongCrcOrSizeIsDamaged() throws {
        let zip = try fixture("sample.1pux"), c = central(zip)
        var crc = zip; crc[c + 16] ^= 1
        assertRefused(crc, ZipReader.damagedMessage)
        var size = zip; put32(&size, c + 24, 1474)
        assertRefused(size, ZipReader.damagedMessage)
    }

    func testDeclaredSizeOverTheLimitIsTooLarge() throws {
        var zip = try fixture("sample.1pux"); put32(&zip, central(zip) + 24, Records.maxBytes + 1)
        assertRefused(zip, ZipReader.tooLargeMessage)
    }

    func testEncryptedEntriesAndOtherMethodsAreUnsupported() throws {
        let zip = try fixture("sample.1pux"), c = central(zip)
        var encrypted = zip; encrypted[c + 8] |= 1
        assertRefused(encrypted, ZipReader.unsupportedMessage)
        var bzip2 = zip; bzip2[c + 10] = 12
        assertRefused(bzip2, ZipReader.unsupportedMessage)
    }

    func testDamagedDeflateStreamAndDirectoryAreDamaged() throws {
        let zip = try fixture("sample.1pux"), c = central(zip)
        let local = u32(zip, c + 42)
        var stream = zip; stream[local + 30 + u16(zip, local + 26) + u16(zip, local + 28)] = 7 // reserved block type
        assertRefused(stream, ZipReader.damagedMessage)
        var offset = zip; put32(&offset, end(zip) + 16, end(zip) + 1)
        assertRefused(offset, ZipReader.damagedMessage)
        assertRefused(Array(zip.prefix(20)), ZipReader.damagedMessage)
        var disks = zip; disks[end(zip) + 4] = 1
        assertRefused(disks, ZipReader.damagedMessage)
    }

    // The local header (and data descriptor) must agree with the central directory. Android's reader refuses each of these
    // the same way; iOS used to read the directory's copy and ignore the local one.
    private func local(_ z: [UInt8]) -> Int { u32(z, central(z) + 42) }
    private func dataStart(_ z: [UInt8]) -> Int { local(z) + 30 + u16(z, local(z) + 26) + u16(z, local(z) + 28) }
    private func put16(_ z: inout [UInt8], _ o: Int, _ v: Int) { z[o] = UInt8(v & 0xFF); z[o + 1] = UInt8(v >> 8) }

    func testALocalHeaderThatDisagreesWithTheDirectoryIsDamaged() throws {
        let zip = try fixture("sample.1pux"), l = local(zip)
        var encrypted = zip; encrypted[l + 6] |= 1
        assertRefused(encrypted, ZipReader.damagedMessage)
        var renamed = zip; renamed[l + 30] = UInt8(ascii: "E")
        assertRefused(renamed, ZipReader.damagedMessage)
        var crc = zip; crc[l + 14] ^= 1
        assertRefused(crc, ZipReader.damagedMessage)
        var stored = zip; put16(&stored, l + 8, 0)
        assertRefused(stored, ZipReader.damagedMessage)
        var compressed = zip; put32(&compressed, l + 18, u32(zip, l + 18) + 1)
        assertRefused(compressed, ZipReader.damagedMessage)
        var descriptor = zip; descriptor[l + 6] |= 8 // a descriptor the directory does not have
        assertRefused(descriptor, ZipReader.damagedMessage)
    }

    func testAStreamEndingBeforeItsCompressedSizeIsDamaged() throws {
        var zip = try fixture("sample.1pux"); let c = central(zip), l = local(zip)
        // Both headers claim one more byte than the DEFLATE stream uses: the next header's first byte.
        put32(&zip, c + 20, u32(zip, c + 20) + 1); put32(&zip, l + 18, u32(zip, l + 18) + 1)
        assertRefused(zip, ZipReader.damagedMessage)
    }

    func testDataDescriptorsAreReadAndMustAgreeWithTheDirectory() throws {
        let zip = try fixture("data-descriptor.1pux"), c = central(zip), l = local(zip)
        XCTAssertEqual(u16(zip, c + 8) & 8, 8)
        XCTAssertEqual(try ZipReader.entry(zip, name: "export.data"), try ZipReader.entry(try fixture("sample.1pux"), name: "export.data"))
        let descriptor = dataStart(zip) + u32(zip, c + 20)
        XCTAssertEqual(u32(zip, descriptor), 0x08074B50)
        for field in [4, 8, 12] { // CRC, compressed size, size
            var changed = zip; changed[descriptor + field] ^= 1
            assertRefused(changed, ZipReader.damagedMessage)
        }
        var noFlag = zip; noFlag[l + 6] &= ~8 // the local header no longer announces the descriptor
        assertRefused(noFlag, ZipReader.damagedMessage)
    }
}
