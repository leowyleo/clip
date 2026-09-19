# Acceptance contract

Completion is a user-visible result, not a successful build alone.

## Language

- Clip follows the first macOS preferred language: Simplified Chinese uses the Simplified Chinese UI; English uses the English UI.
- Traditional Chinese, Japanese, Korean, and every other unsupported first language fall back to English.
- Clip has no in-app language switch; changing the macOS preferred language takes effect the next time Clip launches.

## Region capture

- The shortcut can be invoked while another app is focused.
- Dragging on every attached display produces the intended pixel region.
- Minimal is the default; releasing the pointer captures once, dismisses the overlay, and copies immediately.
- The pasted PNG matches the selected region at Retina resolution.
- Escape cancels without changing the clipboard.

## Advanced capture

- Settings persists Minimal and Advanced; Advanced applies the same editing tools to both region and scrolling captures.
- After selection, the captured pixels remain exactly over the selected region and the toolbar prefers the space directly below it.
- The selected region remains bright while every unselected display area stays dimmed; the first drag's mouse-up immediately starts capture and opens the thin editor frame—no second confirmation action is required on the selection overlay.
- In the advanced editor, dragging while no annotation tool is active creates a second crop selection with a high-contrast accent-color border and corner handles; finishing outputs only that crop.
- Double-clicking the neutral editor canvas follows the same completion path as the checkmark button and produces the normal copy-success feedback.
- No annotation tool is active when the editor opens; mosaic changes pixels only after its button is pressed.
- The text tool is represented by a `T`, and the completion action is represented by a checkmark.
- Dragging the mosaic, rectangle, or ellipse tool stays inside the selected region and does not flash or move the backdrop.
- Plain-line and arrow-line tools preserve the drag endpoints; only the arrow tool draws an arrowhead.
- Mosaic strokes conceal the source pixels under the brush path.
- Text notes and rectangle/ellipse marks appear at the user-selected coordinates; inline text shows only the caret and text over the source pixels, with no panel, fill, border, or rounded container. It focuses immediately, grows with text, commits in place on Return, and exits the text tool.
- OCR recognizes the untouched selected pixels locally, copies readable text, closes the editor, and shows “OCR text copied” or “文字 OCR 复制成功” in the selected language.
- OCR success does not run the image clipboard handoff, so recognized text remains on the clipboard.
- Download writes a uniquely named PNG to Downloads without closing the editor or replacing the clipboard.
- Command-Z removes one annotation action; Escape cancels; Done copies one annotated PNG.
- The selection outline, toolbar, inline text field, and status feedback do not enter the final image.
- Every interactive toolbar target is at least 40 × 40 pt.
- A completed scrolling image opens at the selected width in a vertical viewport; it is not shrunk to fit the original selection height.
- Scrolling within the editor reaches the entire long image, and annotations stay attached to the intended long-image coordinates.

## Scrolling capture

- The flow does not inspect the target app name or use app-specific code.
- Static vertical content works in a browser, Finder, Terminal, a code editor, a PDF reader, and a chat-style view.
- A fixed top band appears once in the final image.
- The capture stops at the bottom without appending duplicate frames.
- Normal fast trackpad movement retains enough frames to prove continuity.
- Finish, cancel, and output-size limits work.
- Finishing always reaches success or an explicit failure within a bounded time.
- Low-confidence, protected, or changing content produces an explicit failure rather than an unverified image.
- Failure text never exposes confidence scores, frame terminology, or cache paths.

## Permissions and privacy

- Both modes guide the user to screen-read permission only when needed.
- The app does not declare or request Accessibility permission.
- Core behavior works with the network disabled.
- OCR uses the local Vision framework and works with the network disabled.
- No successful capture is uploaded or saved as an image file; the result goes to the clipboard.

## Packaging

- The built app declares macOS 13.0 as its minimum system version.
- The universal release executable contains both `arm64` and `x86_64` slices.
- `scripts/test.sh` passes with both a full Xcode selection and a Command Line Tools-only selection.
- `scripts/bundle.sh` produces `dist/Clip.app`.
- `UNIVERSAL=1 scripts/bundle.sh` produces an arm64 + x86_64 executable when full Xcode is available.
- The bundle launches as a menu-bar accessory app.
- The bundle contains the required privacy usage descriptions and version metadata.
