# Clip

## Product boundary

- Clip is a clipboard-first macOS screenshot utility.
- The two primary actions are free rectangular capture and app-agnostic scrolling capture.
- Keep Minimal mode as the default direct-to-clipboard path. Advanced mode may add local-only region annotations and Vision OCR, but must not turn Clip into a general image editor.
- Do not add accounts, cloud upload, recording, a screenshot library, or app-specific adapters.
- Captures and image analysis stay local.
- If stitching cannot be proven reliable, fail visibly and preserve source frames rather than emitting a plausible but incorrect image.

## Engineering

- Target macOS 13 or newer with Swift 6 and AppKit/CoreGraphics.
- Keep capture, scrolling/stitching, and app UI in separate targets.
- Avoid private APIs and avoid bypassing protected content.
- The package must build and test with Command Line Tools; do not require a full Xcode installation.
- Do not commit, push, sign with a distribution identity, or publish without explicit authorization.
