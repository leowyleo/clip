import AppKit

let application = NSApplication.shared
let delegate = ClipAppDelegate()
let coordinator = CaptureCoordinator(appDelegate: delegate)

application.setActivationPolicy(.accessory)
application.delegate = delegate

withExtendedLifetime((delegate, coordinator)) {
    application.run()
}
