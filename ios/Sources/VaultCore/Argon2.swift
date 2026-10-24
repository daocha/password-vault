import Foundation
import Clibsodium

/// Argon2d / Argon2i / Argon2id (RFC 9106, versions 0x10 and 0x13) with any number of lanes, for opening KeePass databases.
/// libsodium's own Argon2 is single-lane Argon2i/id only; this uses its BLAKE2b. Lanes are filled one after another (same result).
public enum Argon2 {
    public enum Variant: UInt32 { case d = 0, i = 1, id = 2 }
    public static func hash(password: [UInt8], salt: [UInt8], secret: [UInt8] = [], associated: [UInt8] = [], iterations: Int, memoryKiB: Int, lanes: Int,
                            variant: Variant, version: UInt32 = 0x13, length: Int = 32) throws -> [UInt8] {
        guard VaultCrypto.initialized, iterations >= 1, lanes >= 1, lanes <= 0xFFFFFF, length >= 4, version == 0x10 || version == 0x13, salt.count >= 8 else {
            throw VaultError.invalid("Unsupported key derivation settings.")
        }
        let blocks = max(memoryKiB, 8 * lanes) / (4 * lanes) * (4 * lanes), laneLength = blocks / lanes, segment = laneLength / 4
        func le32(_ v: Int) -> [UInt8] { let x = UInt32(truncatingIfNeeded: v); return [UInt8(x & 255), UInt8(x >> 8 & 255), UInt8(x >> 16 & 255), UInt8(x >> 24 & 255)] }
        var h0Input = le32(lanes) + le32(length) + le32(memoryKiB) + le32(iterations) + le32(Int(version)) + le32(Int(variant.rawValue))
        h0Input += le32(password.count) + password + le32(salt.count) + salt + le32(secret.count) + secret + le32(associated.count) + associated
        let h0 = blake2b(h0Input, 64)

        let memory = UnsafeMutablePointer<UInt64>.allocate(capacity: blocks * 128)
        defer { memory.update(repeating: 0, count: blocks * 128); memory.deallocate() }
        func block(_ index: Int) -> UnsafeMutablePointer<UInt64> { memory + index * 128 }
        func load(_ bytes: [UInt8], into target: UnsafeMutablePointer<UInt64>) {
            for w in 0..<128 { var v: UInt64 = 0; for b in 0..<8 { v |= UInt64(bytes[w * 8 + b]) << (8 * UInt64(b)) }; target[w] = v }
        }
        for lane in 0..<lanes {
            load(hPrime(h0 + le32(0) + le32(lane), 1024), into: block(lane * laneLength))
            load(hPrime(h0 + le32(1) + le32(lane), 1024), into: block(lane * laneLength + 1))
        }
        let scratch = UnsafeMutablePointer<UInt64>.allocate(capacity: 128 * 6); defer { scratch.deallocate() }
        let zero = scratch, input = scratch + 128, address = scratch + 256, temp = scratch + 384, work = scratch + 512
        for pass in 0..<iterations {
            for slice in 0..<4 {
                for lane in 0..<lanes {
                    let independent = variant == .i || (variant == .id && pass == 0 && slice < 2)
                    if independent {
                        zero.update(repeating: 0, count: 128); input.update(repeating: 0, count: 128)
                        input[0] = UInt64(pass); input[1] = UInt64(lane); input[2] = UInt64(slice); input[3] = UInt64(blocks); input[4] = UInt64(iterations); input[5] = UInt64(variant.rawValue)
                    }
                    func nextAddresses() { input[6] &+= 1; compress(zero, input, into: temp, xor: false, work: work); compress(zero, temp, into: address, xor: false, work: work) }
                    let start = pass == 0 && slice == 0 ? 2 : 0
                    if independent && start == 2 { nextAddresses() }
                    var current = lane * laneLength + slice * segment + start
                    var previous = current % laneLength == 0 ? current + laneLength - 1 : current - 1
                    for index in start..<segment {
                        if current % laneLength == 1 { previous = current - 1 }
                        let random: UInt64
                        if independent { if index % 128 == 0 { nextAddresses() }; random = address[index % 128] } else { random = block(previous)[0] }
                        let refLane = pass == 0 && slice == 0 ? lane : Int((random >> 32) % UInt64(lanes))
                        let sameLane = refLane == lane
                        let area: Int
                        if pass == 0 { area = slice == 0 ? index - 1 : sameLane ? slice * segment + index - 1 : slice * segment + (index == 0 ? -1 : 0) }
                        else { area = sameLane ? laneLength - segment + index - 1 : laneLength - segment + (index == 0 ? -1 : 0) }
                        var relative = random & 0xFFFFFFFF
                        relative = (relative &* relative) >> 32
                        relative = UInt64(area) - 1 - ((UInt64(area) &* relative) >> 32)
                        let startPosition = pass == 0 || slice == 3 ? 0 : (slice + 1) * segment
                        let column = (startPosition + Int(relative)) % laneLength
                        compress(block(previous), block(refLane * laneLength + column), into: block(current), xor: version == 0x13 && pass > 0, work: work)
                        current += 1; previous += 1
                    }
                }
            }
        }
        let final = UnsafeMutablePointer<UInt64>.allocate(capacity: 128); defer { final.deallocate() }
        final.update(from: block(laneLength - 1), count: 128)
        for lane in 1..<lanes { let b = block(lane * laneLength + laneLength - 1); for w in 0..<128 { final[w] ^= b[w] } }
        var bytes = [UInt8](repeating: 0, count: 1024)
        for w in 0..<128 { for b in 0..<8 { bytes[w * 8 + b] = UInt8(truncatingIfNeeded: final[w] >> (8 * UInt64(b))) } }
        defer { sodium_memzero(&bytes, bytes.count) }
        return hPrime(bytes, length)
    }

    static func blake2b(_ input: [UInt8], _ length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        _ = crypto_generichash(&out, length, input, UInt64(input.count), nil, 0)
        return out
    }
    /// The variable-length hash H' of RFC 9106 §3.3.
    static func hPrime(_ input: [UInt8], _ length: Int) -> [UInt8] {
        let prefix = [UInt8(length & 255), UInt8(length >> 8 & 255), UInt8(length >> 16 & 255), UInt8(length >> 24 & 255)]
        if length <= 64 { return blake2b(prefix + input, length) }
        let r = (length + 31) / 32 - 2
        var v = blake2b(prefix + input, 64), out = Array(v.prefix(32))
        for _ in 1..<r { v = blake2b(v, 64); out += v.prefix(32) }
        return out + blake2b(v, length - 32 * r)
    }
    /// The compression function G: `target = P(x ^ y) ^ x ^ y`, or XORed into `target` (version 0x13 after the first pass).
    /// `work` is 256 words of scratch space.
    static func compress(_ x: UnsafeMutablePointer<UInt64>, _ y: UnsafeMutablePointer<UInt64>, into target: UnsafeMutablePointer<UInt64>, xor: Bool, work: UnsafeMutablePointer<UInt64>) {
        let r = work, q = work + 128
        for w in 0..<128 { r[w] = x[w] ^ y[w] }
        q.update(from: r, count: 128)
        // Rows are 16 consecutive words; column c is words 2c and 2c+1 of each of the 8 rows.
        for row in 0..<8 { let b = row * 16; permute(q, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7, b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15) }
        for col in 0..<8 { let c = 2 * col; permute(q, c, c + 1, c + 16, c + 17, c + 32, c + 33, c + 48, c + 49, c + 64, c + 65, c + 80, c + 81, c + 96, c + 97, c + 112, c + 113) }
        if xor { for w in 0..<128 { target[w] ^= q[w] ^ r[w] } } else { for w in 0..<128 { target[w] = q[w] ^ r[w] } }
    }
    @inline(__always) static func gb(_ v: UnsafeMutablePointer<UInt64>, _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        @inline(__always) func mix(_ x: UInt64, _ y: UInt64) -> UInt64 { x &+ y &+ 2 &* (x & 0xFFFFFFFF) &* (y & 0xFFFFFFFF) }
        @inline(__always) func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }
        v[a] = mix(v[a], v[b]); v[d] = rotr(v[d] ^ v[a], 32); v[c] = mix(v[c], v[d]); v[b] = rotr(v[b] ^ v[c], 24)
        v[a] = mix(v[a], v[b]); v[d] = rotr(v[d] ^ v[a], 16); v[c] = mix(v[c], v[d]); v[b] = rotr(v[b] ^ v[c], 63)
    }
    @inline(__always) static func permute(_ v: UnsafeMutablePointer<UInt64>, _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int, _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int,
                                          _ i8: Int, _ i9: Int, _ i10: Int, _ i11: Int, _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        gb(v, i0, i4, i8, i12); gb(v, i1, i5, i9, i13); gb(v, i2, i6, i10, i14); gb(v, i3, i7, i11, i15)
        gb(v, i0, i5, i10, i15); gb(v, i1, i6, i11, i12); gb(v, i2, i7, i8, i13); gb(v, i3, i4, i9, i14)
    }
}
