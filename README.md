# ScreenshotApp

A lightweight macOS screenshot utility that lives exclusively in the menu bar. No Dock icon. Built with Swift Package Manager — no Xcode project required.

---

## Features

- **Area selection** — drag to select any region of any screen
- **Move & resize selection** — drag to reposition, 8 handles to resize, before capture commits
- **Annotation tools** — blur, rectangle, ellipse, line, arrow, with color picker and stroke size
- **Undo** — Delete key or ⌘Z / ⌃Z removes the last annotation
- **Two output actions** — Save to folder (⬇) or Copy to clipboard (⎘); Enter = clipboard
- **ScreenCaptureKit capture** — macOS 14+: captures at true native panel resolution via SCK; macOS 13: falls back to CGDisplayCreateImage
- **Retina-correct DPI** — output PNG/JPEG carries dynamic DPI metadata (72 × pixel/point scale), so images paste at the right physical size in Slack, Notion, browsers, etc.
- **Multi-monitor** — overlay always opens on whichever screen the cursor is on
- **Global hotkey** — default ⌃⇧4, fully configurable in Settings
- **PNG or JPEG** — selectable in Settings; JPEG uses 0.95 quality
- **Tool sizes persist** — blur radius and stroke width are saved to UserDefaults and restored on next launch
- **Launch at Login** — auto-registered on first run; toggle via menu bar → Launch at Login

---

## Requirements

- macOS 13 Ventura or later
- No App Store / sandbox — the app runs unsigned (ad-hoc signed) with no sandbox entitlement, which is required for global hotkeys (Carbon) and full-screen capture

---

## Building

```bash
bash build.sh
```

This runs `swift build -c release`, assembles `ScreenshotApp.app`, copies `Resources/Info.plist` and `Resources/AppIcon.icns`, then ad-hoc signs the bundle with `ScreenshotApp.entitlements`.

Output: `ScreenshotApp.app` in the project root.

### Install to /Applications

```bash
cp -r ScreenshotApp.app /Applications/ScreenshotApp.app
```

First launch: right-click → **Open** (or run `xattr -cr /Applications/ScreenshotApp.app`) to bypass Gatekeeper, since the app is not notarized.

After installing to a new location, re-toggle **Launch at Login** in the menu to update the login item registration to the new path.

---

## Project Structure

```
screenshot-app/
├── build.sh                        # Build + bundle + sign script
├── Package.swift                   # SPM manifest (macOS 13+, Carbon linked)
├── ScreenshotApp.entitlements      # sandbox=false (required for Carbon hotkeys)
├── gen_icon.swift                  # One-off script used to generate AppIcon.icns
├── Resources/
│   ├── Info.plist                  # Bundle ID, version, NSPrincipalClass
│   └── AppIcon.icns                # Menu bar + Dock icon
└── Sources/ScreenshotApp/
    ├── main.swift                  # Entry point — sets .accessory policy BEFORE run()
    ├── AppDelegate.swift           # Menu bar setup, hotkey wiring, clipboard write, SMAppService
    ├── CaptureOverlay.swift        # All capture + annotation UI (largest file)
    ├── HotkeyManager.swift         # Carbon RegisterEventHotKey wrapper
    ├── ImageSaver.swift            # Writes PNG/JPEG with dynamic DPI metadata
    ├── SettingsManager.swift       # UserDefaults-backed settings singleton
    └── SettingsWindow.swift        # SwiftUI settings panel + hotkey recorder
```

---

## Architecture

### No Dock icon

`NSApplication.shared.setActivationPolicy(.accessory)` is called in `main.swift` **before** `NSApplication.shared.run()`. Setting it later (e.g. in `applicationDidFinishLaunching`) causes a brief Dock flash. `NSApp.activate(ignoringOtherApps:)` is never called — that call re-shows the Dock icon for `.accessory` apps.

### Capture flow

```
HotkeyManager (Carbon)
    └─→ AppDelegate.takeScreenshot()
            └─→ CaptureOverlayWindow.show()          [NSPanel, .nonactivatingPanel]
                    └─→ SelectionView (Phase 1)       [CA-layer based, no draw()]
                            └─→ captureAndAnnotate()
                                    ├─ macOS 14+: sckCapture()      [SCK, native panel res]
                                    └─ macOS 13:  captureWithCGDisplay()  [CGDisplayCreateImage]
                                            └─→ buildCroppedImage()   [shared crop helper]
                                                    └─→ AnnotationView (Phase 2)
                                                            └─→ buildFinalImage()
                                                                    └─→ AppDelegate callback
                                                                            ├─ clipboard (NSPasteboard PNG)
                                                                            └─ ImageSaver.save()
```

### NSPanel trick (key events without Dock icon)

The overlay uses `NSPanel` with `.nonactivatingPanel` style mask. This allows the panel to become the key window (receives ESC, Enter, key events) without activating the application — so the Dock icon never appears. `canBecomeKey` and `canBecomeMain` are both overridden to return `true`.

### ScreenCaptureKit capture (macOS 14+)

`captureAndAnnotate` branches on `#available(macOS 14, *)`:

1. `SCShareableContent.current` (async) finds the `SCDisplay` matching the overlay's `CGDirectDisplayID`
2. `CGDisplayCopyDisplayMode` → `mode.pixelWidth / pixelHeight` gives the **native panel** pixel dimensions (e.g. 3456×2234 on M3 MBP 16"), which is higher than `CGDisplayCreateImage`'s virtual framebuffer (3024×1964 on the same machine)
3. `SCStreamConfiguration` is set to those native dimensions with `showsCursor = false`
4. `SCScreenshotManager.captureImage(contentFilter:configuration:)` performs the capture asynchronously
5. Falls back to `captureWithCGDisplay` if SCK throws (e.g. permission not yet granted)

### Image crop and DPI

`buildCroppedImage(full:imageW:imageH:screenW:screenH:selectionRect:)` is a static helper shared by both capture paths:

- Converts the selection rect from AppKit coordinates (Y-up, origin bottom-left) to pixel coordinates (Y-down, origin top-left)
- Uses a `CGContext` draw (not `CGImage.cropping`) to preserve the display's color space (Display P3, etc.)
- Wraps the result in `NSBitmapImageRep` with `rep.size = selectionRect.size` (logical points), so `pixelsWide / size.width` gives the exact scale factor (e.g. 2.0) — `ImageSaver` reads this to compute DPI = `72 × scale` dynamically

### Selection overlay — flicker-free CA layers

`SelectionView` uses **Core Animation layers exclusively** — no `draw()` override:

- `frameLayer` (`CAShapeLayer`, `fillRule = .evenOdd`): path = full bounds rect + selection rect → the even-odd rule punches a transparent hole atomically in one compositing pass, eliminating the flicker that `draw()` caused (it briefly showed a fully-dark frame between filling the overlay and clearing the hole)
- `borderLayer` (`CAShapeLayer`): selection border, dashed when placed
- `CATextLayer`: "W × H" size badge while drawing
- `CALayer` circles: corner handles when placed/dragging
- All updates wrapped in `CATransaction.setDisableActions(true)` → no implicit animations, single compositing pass per mouse event

### Annotation view — blur implementation

Blur is a two-pass operation:

**Preview** (`draw()`):
1. Dark overlay fills the view
2. Clear blend mode punches the selection area transparent (real screen shows through)
3. Blur action rects: `applyBlurCI(cgImageRef)` runs CIGaussianBlur on the captured CGImage; result is cached as `NSImage` (`cachedBlurImg`); `NSImage.draw(in: selectionRect)` clipped to the blur rect paints the blurred content — `NSImage.draw` is used instead of `ctx.draw(cgImage)` to avoid Y-axis orientation issues between CIContext's CGImage output and NSView's drawing context

**Final output** (`buildFinalImage()`):
- Runs `applyBlurCI` fresh at full pixel resolution
- Creates a `CGContext` at the image's actual pixel dimensions (e.g. 1920×1006)
- Draws base image, then scales by `pixelScaleX/Y` and renders annotation shapes via `NSBezierPath` — shapes are in view-local coordinates, scaling maps them to pixel space
- Result wrapped in `NSBitmapImageRep` with `size = image.size` to preserve DPI

### CGImage extraction

`AnnotationView.init` extracts the CGImage via:
```swift
image.representations.compactMap({ $0 as? NSBitmapImageRep }).first?.cgImage
```
**Not** `image.cgImage(forProposedRect: nil, context: nil, hints: nil)` — the latter with `context: nil` renders at 1× scale on some macOS versions, returning a downsampled image. This would make `pixelScaleX/Y = 1.0`, breaking blur region placement and final image resolution.

### Settings persistence (UserDefaults keys)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `savePath` | String | `~/Pictures/Screenshots` | Folder for saved screenshots |
| `hotkeyKeyCode` | Int | 21 (key `4`) | Carbon key code for the hotkey |
| `hotkeyModifiers` | Int | `kControlKey \| kShiftKey` | Carbon modifier flags |
| `imageFormat` | String | `"png"` | `"png"` or `"jpeg"` |
| `blurRadius` | Double | 20 | Blur tool radius (scroll wheel to adjust) |
| `strokeWidth` | Double | 3 | Drawing tool stroke width (scroll wheel to adjust) |
| `launchAtLoginRegistered` | Bool | false | Set to true after first-launch SMAppService.register() call |

---

## Known constraints

- **Not sandboxed** — required for Carbon global hotkeys and `CGRequestScreenCaptureAccess`. Cannot be distributed via the Mac App Store without significant rework.
- **Ad-hoc signed only** — not notarized. First launch requires right-click → Open or `xattr -cr`.
- **Launch at Login path-sensitive** — `SMAppService` registers the app at its current path. If the `.app` bundle is moved, re-toggle Launch at Login to update the registration.
- **Screen Recording permission** — must be granted in System Settings → Privacy & Security → Screen Recording. The app requests it on launch via `CGRequestScreenCaptureAccess()`.
