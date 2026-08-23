# Architecture

Clip is split by responsibility so the normal screenshot path stays small and scrolling complexity remains testable without the UI.

## Targets

### ClipCore

Shared value types and user-facing errors. It contains no AppKit UI and no global process state.

### ClipCapture

Screen-read permission, global-coordinate region capture, image encoding, and clipboard handoff. System capture and pasteboard access sit behind protocols so behavior can be tested without changing the real clipboard.

### ClipScroll

Frame comparison, overlap matching, stitching, confidence thresholds, duplicate detection, and output limits. It does not know which app is underneath the selected rectangle.

### ClipApp

Menu-bar lifecycle, shortcuts, selection overlays, the opt-in annotation canvas, local Vision OCR, permission guidance, capture HUD, success toast, settings, and orchestration of the other targets.

## Capture pipelines

```text
Region shortcut (Minimal)
  -> selection overlay
  -> screen permission
  -> region capture
  -> clipboard
  -> transient “Copied” toast

Region shortcut (Advanced)
  -> selection overlay
  -> screen permission
  -> region capture
  -> freeze the captured pixels in place
  -> mosaic / text / rectangle / ellipse / line / arrow annotations or local OCR
  -> render only the source pixels and annotations
  -> clipboard, or an explicit PNG download
  -> transient “Copied” toast

Scrolling shortcut
  -> selection overlay
  -> screen permission
  -> start an in-memory SCStream for the selected region
  -> accept the first complete frame
  -> keep a passive, mouse-through selection frame on screen
  -> user scrolls the underlying app
  -> continuously inspect complete frames at up to 30 FPS
  -> discard unchanged frames
  -> estimate signed vertical motion from grayscale edge profiles and ZNCC
  -> update global content coverage; retain only coverage keyframes
  -> finish when the user clicks Done
  -> verify every output overlap or fail closed and preserve keyframes
  -> in Advanced mode, browse the long image at the selected width and use the same annotation / OCR / download tools
  -> clipboard
  -> transient “Copied” toast
```

## Coordinate contract

Selection is represented in global AppKit screen coordinates while pointer interaction is active. The capture boundary converts exactly once into the Quartz coordinate space used by the screen-capture API. Image pixel dimensions are derived from the returned image, not assumed to equal point dimensions, so Retina scaling and mixed displays remain explicit.

## Stitching contract

While the user scrolls, ScreenCaptureKit supplies complete BGRA screen frames for the selected region through `SCStream` at up to 30 FPS. Frames remain in memory; Clip never adds an `SCRecordingOutput`, encodes a movie, or writes a video file. An `AsyncThrowingStream` keeps a bounded 12-frame burst so fast trackpad input does not lose required overlap while image analysis briefly catches up. The user decides when the intended content is complete by clicking Done; Clip does not guess at a scroll container or page bottom.

After the initial screenshot, the selection overlay changes into a passive frame: the dimming mask and size label disappear, its windows ignore mouse events, and the previously active app regains input. The frame stays fixed until Done, Escape, or failure. Clip excludes its own windows from every screenshot, so neither the frame nor the Done control appears in the final image.

Each incoming frame is reduced to a grayscale edge profile. ZNCC searches signed vertical displacement in both directions with at least 20% viewport overlap. Reliable movement updates a global content coordinate; unchanged frames are discarded, movement inside already-covered coordinates is treated as rollback, and only frames that extend coverage by a useful distance are retained. Before fast motion can push two retained keyframes beyond the verifiable overlap, the preceding analyzed frame is retained as a bridge. The rightmost scrollbar gutter is excluded from motion analysis, fixed top content is tolerated by the dynamic-feature threshold, and the cursor plus Clip's own windows are excluded at capture time.

Clicking Done closes the consumer-facing frame sequence immediately; final composition never waits for ScreenCaptureKit's asynchronous stop callback. Already-buffered tail frames are drained before composition so the user's final scroll position is not discarded. Covered pixel limits are enforced as frames arrive, before additional keyframes are retained. Oversized captures therefore stop with an explicit error instead of allocating the rejected output during finalization.

After the user clicks Done, retained keyframes are sorted by global content coordinate. Every adjacent overlap is verified again at pixel-row precision. Composition starts from the earliest full raw frame and appends only raw pixel rows that are not already covered. There is no blending, perspective correction, watermark, border, or product UI in the result.

The final PNG is encoded directly from the composed `CGImage` on a utility task. Only the completed PNG handoff touches the main actor and system pasteboard.

## Advanced annotation contract

Advanced mode is opt-in and applies to both region and scrolling captures. A region `CGImage` is displayed at the original selection rectangle. A long scrolling `CGImage` keeps the selected width and is placed in a vertically scrollable viewport at the original rectangle, so it is never compressed into an unusable thumbnail. One mouse-transparent backdrop per display keeps all unselected areas dim. The initial drag outline is removed once editing starts; visual focus comes only from the bright selection against the dim surroundings. An excluded, non-capturable toolbar is placed below the selection. Annotation coordinates remain in image-display points while the final renderer targets the original image pixel dimensions, preserving Retina output. The viewport scroller, backdrop, toolbar, inline text field, and status messages are never rendered into the PNG.

No annotation tool is active when the editor opens. Mosaic starts only after its button is pressed and uses a locally pixelated copy of the captured image clipped to brush paths. The text control uses an explicit `T` glyph; clicking a point opens one focused inline field directly over the source pixels, with no panel, fill, border, or rounded container. Its width follows the content, Return commits the text in place, and the editor returns to the neutral tool state. Rectangle/ellipse marks and plain/arrowed lines are explicit user annotations; line direction preserves the user's drag direction. OCR always reads the untouched source image with macOS Vision, keeps small readable Retina text eligible for recognition, detects language locally, and copies recognized text only after the user presses OCR. Successful OCR produces a terminal `ocrTextCopied` result: the editor closes before a dedicated success toast appears, and the normal image encoder is bypassed so the recognized text is not overwritten. It does not send pixels or text to a network service. The download action atomically writes a uniquely named PNG into Downloads without closing the editor. Escape cancels, Command-Z removes one annotation action, and the checkmark renders the annotated image before the normal clipboard handoff.

Final composition and PNG encoding share one eight-second user-facing deadline. If a system API or encoder does not return, the UI exits the finishing state with an explicit failure; late work cannot write to the clipboard or change the UI. Diagnostic keyframes may be archived in the background, but archiving never delays or changes the user-facing result and its filesystem path is not displayed.

The engine stops rather than guesses when:

- the best overlap is below the confidence threshold;
- multiple matches are too similar to distinguish reliably;
- too much of the candidate frame is changing;
- the final pixel or memory limit would be exceeded;
- cancellation is requested.

Frames remain available until the operation succeeds or background diagnostics have taken ownership. Diagnostic PNG encoding never runs on the UI actor.

## Permission contract

Both modes request screen-read permission just in time. macOS places this control in “Screen & System Audio Recording,” but Clip does not record or save video. Scrolling is controlled by the user, so Clip does not declare or require Accessibility permission and does not synthesize scroll input. Permission denial never exits the app and the UI supplies a direct path to the relevant System Settings pane.

## System compatibility contract

Clip supports macOS 13 Ventura and newer on Apple Silicon and Intel Macs. On macOS 14 and newer, region capture uses `SCScreenshotManager`; Ventura falls back to a short-lived in-memory `SCStream` and stops immediately after the first complete frame. Retina scale on Ventura is derived from the display pixel dimensions because `pointPixelScale` is unavailable there. Properties introduced in macOS 14 or 15 are guarded at runtime, and their older-system defaults preserve the same no-cursor, no-audio screenshot behavior. Neither compatibility path writes a video file.
