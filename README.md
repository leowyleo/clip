# Clip

Clip is a clipboard-first screenshot utility for macOS. It has two primary actions:

- capture any rectangular screen region and copy it immediately;
- capture a scrolling region in any app that macOS can see and normal scroll input can move.

The app is local-only and app-agnostic. It does not upload captures or use per-app adapters.

Capture has two settings:

- Minimal keeps the original select → copy behavior.
- Advanced opens the completed region or scrolling image in place, keeps the surrounding screen dim without retaining a border, and adds opt-in mosaic, a focused `T` text tool, local OCR, rectangle/ellipse marks, plain and arrowed lines, and a one-click download action below the selection. A scrolling image stays at the selected width and can be browsed vertically without shrinking the long image.

Minimal scrolling capture remains select → user scrolls → Done → copy. Advanced scrolling capture adds the same annotation step after the long image is composed.

## Requirements

- macOS 15 or newer
- Swift 6.2 or newer

The app builds with Apple Command Line Tools; a full Xcode installation is not required for the release bundle. The test runner bundled with the current Command Line Tools needs its framework paths supplied explicitly, so using a full Xcode installation is the shortest test path.

## Build and test

```sh
./scripts/test.sh
./scripts/create-local-signing-identity.sh
./scripts/bundle.sh
open dist/Clip.app
```

`scripts/test.sh` automatically uses the selected full Xcode installation or supplies the Testing framework paths required by a Command Line Tools-only installation. You can still select a specific Xcode explicitly:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test.sh
```

`bundle.sh` creates a bundle for the current Mac by default. A full Xcode installation can produce a universal Apple Silicon + Intel bundle:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  UNIVERSAL=1 ./scripts/bundle.sh
```

Run `scripts/create-local-signing-identity.sh` once before the first local bundle. It creates a code-signing-only identity named `Clip Local Development` in the current user's login keychain. `bundle.sh` then reuses that identity so rebuilt bundles keep a stable designated requirement and macOS privacy permissions remain attached to the same app identity. If the identity is missing, bundling fails instead of silently falling back to an unstable ad-hoc signature.

An existing Apple Development or Developer ID identity can be selected instead:

```sh
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./scripts/bundle.sh
```

For local QA or automation, the executable also accepts `--capture-region`,
`--capture-scrolling`, and `--settings`.

On first use, Clip asks for screen-read access. macOS places this control under Screen & System Audio Recording. During a scrolling screenshot, ScreenCaptureKit supplies in-memory screen frames while the user scrolls. Clip does not encode or save video, synthesize scroll input, or declare Accessibility permission. Advanced-mode OCR uses the local Vision framework and does not upload selected pixels or recognized text. Successful OCR closes the editor and leaves the recognized text on the clipboard. An image file is created only when the user explicitly presses the download button.

## Product status

This repository is under active development. See [PRODUCT.md](docs/PRODUCT.md) for the product contract and [ACCEPTANCE.md](docs/ACCEPTANCE.md) for the evidence required before a release can be called complete.
