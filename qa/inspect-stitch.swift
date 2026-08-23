import AppKit
import ClipScroll
import Foundation

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: inspect-stitch <frame-1.png> <frame-2.png> [...frames]\n".utf8))
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
    var configuration = ScrollStitchConfiguration()
    if ProcessInfo.processInfo.environment["CLIP_INSPECT_TOLERANT"] == "1" {
        configuration.minimumConfidence = 0
        configuration.ambiguityTolerance = 0
        configuration.maximumChangedPixelRatio = 1
    }
    let stitcher = ScrollStitcher(configuration: configuration)
    let result = ProcessInfo.processInfo.environment["CLIP_INSPECT_INFER_DIRECTION"] == "1"
        ? try stitcher.stitchInferringDirection(images)
        : try stitcher.stitch(images)
    for transition in result.transitions {
        print(
            "frame=\(transition.frameIndex) step=\(transition.scrollStep) " +
            "runnerStep=\(transition.runnerUpScrollStep.map(String.init) ?? "none") " +
            "overlap=\(transition.overlapHeight) " +
            "appended=\(transition.appendedHeight) fixedTop=\(transition.fixedTopHeight) " +
            "confidence=\(transition.confidence) runnerUp=\(transition.runnerUpConfidence) " +
            "changed=\(transition.changedPixelRatio)"
        )
    }
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
