import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: swift generate_icon.swift OUTPUT.png\n".utf8)
    )
    exit(2)
}

let scriptURL = URL(fileURLWithPath: #filePath)
let projectURL = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let artworkURL = projectURL
    .appendingPathComponent("Resources")
    .appendingPathComponent("AppIconArtwork.png")
let outputURL = URL(fileURLWithPath: arguments[1])

guard let source = CGImageSourceCreateWithURL(artworkURL as CFURL, nil),
      let icon = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ] as CFDictionary
      ),
      icon.width == 1024,
      icon.height == 1024,
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    fatalError("Unable to create the 1024 px app icon")
}

CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to encode app icon")
}
