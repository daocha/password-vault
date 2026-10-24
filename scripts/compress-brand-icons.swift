// Re-encodes the Android brand icons (android/app/src/main/res/drawable-nodpi/brand_*.png) as JPEG, which is far smaller for these
// photographic app icons. Run it after scripts/generate-brand-icons.mjs; it uses only macOS's ImageIO, so it installs nothing:
//
//   swift scripts/compress-brand-icons.swift [directory]
//
// The icons are opaque squares with rounded corners baked in as transparency. The app clips them to the same rounded shape, so the
// transparent corners are first filled with the neighbouring edge colour (no light or dark halo where the clip and the baked corner
// differ by a pixel), then the PNG is replaced by a JPEG of the same name, at most `side` pixels square: icons are shown at 44 dp in
// lists and 72 dp on an entry, so 160 px stays sharp in lists and close to it on the entry page of high-density screens.
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "android/app/src/main/res/drawable-nodpi"
let quality = 0.85, side = 160
var before = 0, after = 0, converted = 0
for name in try FileManager.default.contentsOfDirectory(atPath: directory).sorted() where name.hasPrefix("brand_") && name.hasSuffix(".png") {
    let input = URL(fileURLWithPath: directory).appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fputs("Cannot read \(name)\n", stderr); exit(1)
    }
    let w = min(side, image.width), h = min(side, image.height)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    // Unpremultiplied RGBA is not a supported bitmap context, so draw premultiplied and divide back out below.
    let context = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
        let a = Double(px[i + 3]); for c in 0..<3 { px[i + c] = UInt8(min(255, (Double(px[i + c]) * 255 / a).rounded())) }
        px[i + 3] = 255
    }
    // Grow the opaque area outwards one pixel at a time: each transparent pixel takes the average of its opaque neighbours.
    var pending = (0..<(w * h)).filter { px[$0 * 4 + 3] == 0 }
    while !pending.isEmpty {
        var filled = [(Int, [UInt8])]()
        for p in pending {
            let x = p % w, y = p / w; var sum = [0, 0, 0], count = 0
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h, px[(ny * w + nx) * 4 + 3] == 255 else { continue }
                for c in 0..<3 { sum[c] += Int(px[(ny * w + nx) * 4 + c]) }; count += 1
            } }
            if count > 0 { filled.append((p, sum.map { UInt8($0 / count) })) }
        }
        guard !filled.isEmpty else { fputs("\(name) has no opaque pixels\n", stderr); exit(1) }
        for (p, rgb) in filled { px[p * 4] = rgb[0]; px[p * 4 + 1] = rgb[1]; px[p * 4 + 2] = rgb[2]; px[p * 4 + 3] = 255 }
        let done = Set(filled.map(\.0)); pending.removeAll { done.contains($0) }
    }
    let opaque = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    let output = input.deletingPathExtension().appendingPathExtension("jpg")
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { fputs("Cannot write \(output.path)\n", stderr); exit(1) }
    CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fputs("Cannot write \(output.path)\n", stderr); exit(1) }
    before += (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    after += (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    try FileManager.default.removeItem(at: input); converted += 1
}
print("Converted \(converted) icons: \(before / 1024) KiB of PNG became \(after / 1024) KiB of JPEG.")
