import AppKit
import ClipScroll
import Foundation

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("usage: inspect-continuous-scroll <frame-1.png> <frame-2.png> [...frames]\n".utf8)
    )
    exit(64)
}

let images: [CGImage] = try CommandLine.arguments.dropFirst().map { path in
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return cgImage
}

do {
    var session = try ContinuousScrollSession()
    for image in images {
        let progress = try session.ingest(image)
        print(
            "source=\(progress.sourceFrameCount) retained=\(progress.retainedFrameCount) " +
            "covered=\(progress.coveredHeight) disposition=\(progress.disposition)"
        )
    }
    let result = try session.finalize()
    print(
        "result=\(result.image.width)x\(result.image.height) " +
        "source=\(result.sourceFrameCount) retained=\(result.retainedFrameCount) " +
        "minimumCorrelation=\(result.minimumCorrelation)"
    )
    if let outputPath = ProcessInfo.processInfo.environment["CLIP_INSPECT_OUTPUT"] {
        let representation = NSBitmapImageRep(cgImage: result.image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("output=\(outputPath)")
    }
} catch {
    print("error=\(error)")
    exit(1)
}
