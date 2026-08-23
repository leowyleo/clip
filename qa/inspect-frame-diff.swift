import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: inspect-frame-diff <first.png> <second.png>\n".utf8))
    exit(64)
}

func image(at path: String) throws -> CGImage {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return cgImage
}

func rgba(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
    let bytesPerRow = width * 4
    var storage = [UInt8](repeating: 0, count: bytesPerRow * height)
    let rendered = storage.withUnsafeMutableBytes { buffer -> Bool in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw CocoaError(.coderInvalidValue) }
    return storage
}

let first = try image(at: CommandLine.arguments[1])
let second = try image(at: CommandLine.arguments[2])
guard first.width == second.width, first.height == second.height else {
    print("size_mismatch=\(first.width)x\(first.height),\(second.width)x\(second.height)")
    exit(1)
}

func report(width: Int, height: Int, label: String) throws {
    let lhs = try rgba(first, width: width, height: height)
    let rhs = try rgba(second, width: width, height: height)
    var total = 0
    var maximum = 0
    var changed = 0
    var changedAboveFour = 0
    var samples = 0
    for index in stride(from: 0, to: lhs.count, by: 4) {
        for channel in 0..<3 {
            let difference = abs(Int(lhs[index + channel]) - Int(rhs[index + channel]))
            total += difference
            maximum = max(maximum, difference)
            changed += difference > 0 ? 1 : 0
            changedAboveFour += difference > 4 ? 1 : 0
            samples += 1
        }
    }
    print(
        "\(label)_mean=\(Double(total) / Double(samples)) " +
        "\(label)_max=\(maximum) " +
        "\(label)_changed_ratio=\(Double(changed) / Double(samples)) " +
        "\(label)_changed_above_4_ratio=\(Double(changedAboveFour) / Double(samples))"
    )
}

try report(width: first.width, height: first.height, label: "full")
try report(width: 48, height: 48, label: "thumbnail")
