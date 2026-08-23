#!/usr/bin/env swift

import AppKit
import Foundation

let pasteboard = NSPasteboard.general
print("clipboard_change_count=\(pasteboard.changeCount)")
guard let data = pasteboard.data(forType: .png),
      let representation = NSBitmapImageRep(data: data)
else {
    FileHandle.standardError.write(Data("clipboard_png=missing\n".utf8))
    exit(2)
}

print("png_bytes=\(data.count)")
print("pixel_width=\(representation.pixelsWide)")
print("pixel_height=\(representation.pixelsHigh)")

if CommandLine.arguments.count > 1 {
    let destination = URL(fileURLWithPath: CommandLine.arguments[1])
    try data.write(to: destination, options: .atomic)
    print("saved=\(destination.path)")
}
