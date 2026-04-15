import AppKit
import CoreImage
import CoreGraphics
import ScreenCaptureKit

// MARK: - Action types

enum CaptureAction { case saveToFolder, copyToClipboard }

// MARK: - Drawing types

enum DrawTool: Int { case move = 0, blur = 1, rectangle = 2, ellipse = 3, line = 4, arrow = 5 }

struct DrawAction {
    enum Shape {
        case blur
        case rectangle(color: NSColor, lineWidth: CGFloat)
        case ellipse(color: NSColor, lineWidth: CGFloat)
        case line(color: NSColor, lineWidth: CGFloat)
        case arrow(color: NSColor, lineWidth: CGFloat)
    }
    let shape: Shape
    let start: CGPoint   // view-space coordinates (full-screen AppKit Y-up)
    let end:   CGPoint
}

// 8 resize handles on the selection rect (AppKit Y-up, so "top" = maxY visually)
private enum ResizeHandle {
    case topLeft, top, topRight
    case left,           right
    case bottomLeft, bottom, bottomRight
}

// MARK: - Capture Overlay Window

// NSPanel + .nonactivatingPanel: becomes key window (receives ESC / key events)
// without activating the app — so the Dock icon never appears.
class CaptureOverlayWindow: NSPanel {
    private static var activeWindow: CaptureOverlayWindow?
    private var completion: ((NSImage?, CaptureAction) -> Void)?
    /// The screen this overlay was created on — preserved even after orderOut.
    private var captureScreen: NSScreen?

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }

    static func show(completion: @escaping (NSImage?, CaptureAction) -> Void) {
        // Use the screen the cursor is currently on, not necessarily the main screen.
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
                  ?? NSScreen.main
        guard let screen = screen else { completion(nil, .copyToClipboard); return }
        let win = CaptureOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel],   // borderless + no app activation
            backing: .buffered, defer: false, screen: screen)
        win.captureScreen = screen
        win.completion = completion
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        activeWindow = win
        // accessory-policy app: makeKeyAndOrderFront is enough; NSApp.activate would show Dock icon
        win.makeKeyAndOrderFront(nil)
        win.showSelectionPhase()
    }

    /// ESC is intercepted at the window level so it works even when a toolbar
    /// button has stolen focus after being clicked.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:        // Escape — always close the overlay entirely
            finish(with: nil, action: .copyToClipboard)
        case 36, 76:    // Return / Enter — default action: copy to clipboard
            (contentView as? AnnotationView)?.triggerCopy()
        default:
            super.keyDown(with: event)
        }
    }

    func showSelectionPhase() {
        makeKeyAndOrderFront(nil)
        // accessory-policy app: makeKeyAndOrderFront is enough; NSApp.activate would show Dock icon
        let view = SelectionView(frame: contentView!.bounds)
        view.onSelection = { [weak self] rect in self?.captureAndAnnotate(selectionRect: rect) }
        view.onCancel    = { [weak self] in self?.finish(with: nil, action: .copyToClipboard) }
        contentView = view
        makeFirstResponder(view)
    }

    private func captureAndAnnotate(selectionRect: CGRect) {
        // Hide the overlay immediately — orderOut is synchronous, so the window
        // is removed from the display server before this function returns.
        orderOut(nil)
        guard let screen = captureScreen ?? NSScreen.main else { finish(with: nil, action: .copyToClipboard); return }
        let displayID: CGDirectDisplayID =
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        let screenH = screen.frame.height
        let screenW = screen.frame.width

        if #available(macOS 14, *) {
            Task { [weak self] in
                guard let self else { return }
                // No sleep needed: orderOut is synchronous — the overlay is already
                // gone from the display server.  By the time this async Task reaches
                // its first suspension point (SCShareableContent.current), the GPU
                // compositor has had at least one full frame to update.  This keeps
                // the gap between selection and capture under ~50 ms, giving the
                // browser no time to scroll.
                if let img = await self.sckCapture(displayID: displayID,
                                                   screenW: screenW, screenH: screenH,
                                                   selectionRect: selectionRect) {
                    await MainActor.run { self.showAnnotationPhase(image: img, selectionRect: selectionRect) }
                } else {
                    // SCK denied / unavailable — fall back to CGDisplayCreateImage.
                    // Add a short pause so the compositor definitely has the overlay gone.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.captureWithCGDisplay(displayID: displayID,
                                              screenW: screenW, screenH: screenH,
                                              selectionRect: selectionRect)
                }
            }
        } else {
            // macOS 13: CGDisplayCreateImage is synchronous; give the compositor
            // a moment to composite the frame without the overlay window.
            captureWithCGDisplay(displayID: displayID,
                                  screenW: screenW, screenH: screenH,
                                  selectionRect: selectionRect)
        }
    }

    // MARK: SCK capture (macOS 14+) — captures at TRUE native panel pixel resolution.

    @available(macOS 14, *)
    private func sckCapture(displayID: CGDirectDisplayID,
                             screenW: CGFloat, screenH: CGFloat,
                             selectionRect: CGRect) async -> NSImage? {
        do {
            let content = try await SCShareableContent.current
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID })
            else { return nil }

            // Prefer CGDisplayMode for native panel pixel dimensions (e.g. 3456×2234 on M3 MBP 16").
            let nativeW: Int
            let nativeH: Int
            if let mode = CGDisplayCopyDisplayMode(displayID) {
                nativeW = mode.pixelWidth
                nativeH = mode.pixelHeight
            } else {
                nativeW = scDisplay.width
                nativeH = scDisplay.height
            }

            let config = SCStreamConfiguration()
            config.width        = nativeW
            config.height       = nativeH
            config.showsCursor  = false

            let filter  = SCContentFilter(display: scDisplay, excludingWindows: [])
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)

            return Self.buildCroppedImage(full: cgImage,
                                          imageW: cgImage.width, imageH: cgImage.height,
                                          screenW: screenW, screenH: screenH,
                                          selectionRect: selectionRect)
        } catch {
            return nil
        }
    }

    // MARK: CGDisplay capture (macOS 13 fallback)

    private func captureWithCGDisplay(displayID: CGDirectDisplayID,
                                       screenW: CGFloat, screenH: CGFloat,
                                       selectionRect: CGRect) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            Thread.sleep(forTimeInterval: 0.016) // one display frame — orderOut is synchronous so overlay is already gone
            guard let full = CGDisplayCreateImage(displayID) else {
                DispatchQueue.main.async { self.showPermissionAlert() }
                return
            }
            let img = Self.buildCroppedImage(full: full,
                                              imageW: full.width, imageH: full.height,
                                              screenW: screenW, screenH: screenH,
                                              selectionRect: selectionRect)
            DispatchQueue.main.async {
                guard let img else { self.finish(with: nil, action: .copyToClipboard); return }
                self.showAnnotationPhase(image: img, selectionRect: selectionRect)
            }
        }
    }

    // MARK: Shared crop helper

    /// Crops `full` to the selection rect in AppKit coordinates.
    /// Uses a CGContext draw (not CGImage.cropping) so the display color space
    /// (Display P3, etc.) is preserved and coordinate rounding is exact.
    /// Sets NSBitmapImageRep.size to logical points so DPI = 72×scale is
    /// written correctly to both files and clipboard.
    private static func buildCroppedImage(full: CGImage,
                                           imageW: Int, imageH: Int,
                                           screenW: CGFloat, screenH: CGFloat,
                                           selectionRect: CGRect) -> NSImage? {
        let scaleX = CGFloat(imageW) / screenW
        let scaleY = CGFloat(imageH) / screenH

        // Convert selection (AppKit Y-up, origin bottom-left) → pixel rect (CG Y-down, top-left).
        let pxI = Int((selectionRect.origin.x * scaleX).rounded())
        let pyI = Int(((screenH - selectionRect.origin.y - selectionRect.height) * scaleY).rounded())
        let pwI = max(1, Int((selectionRect.width  * scaleX).rounded()))
        let phI = max(1, Int((selectionRect.height * scaleY).rounded()))

        let colorSpace = full.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: nil, width: pwI, height: phI,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo.rawValue) else { return nil }

        // Draw the full display image shifted so the selection lands at the context origin.
        ctx.draw(full, in: CGRect(
            x: CGFloat(-pxI),
            y: CGFloat(-(imageH - pyI - phI)),
            width:  CGFloat(imageW),
            height: CGFloat(imageH)
        ))

        guard let cropped = ctx.makeImage() else { return nil }

        // NSBitmapImageRep with logical size → DPI = 72 × (pixelsWide / size.width) is automatic.
        let rep = NSBitmapImageRep(cgImage: cropped)
        rep.size = selectionRect.size
        let img = NSImage(size: selectionRect.size)
        img.addRepresentation(rep)
        return img
    }

    private func showAnnotationPhase(image: NSImage, selectionRect: CGRect) {
        makeKeyAndOrderFront(nil)
        // accessory-policy app: makeKeyAndOrderFront is enough; NSApp.activate would show Dock icon
        let view = AnnotationView(frame: contentView!.bounds, image: image, selectionRect: selectionRect)
        view.onSaveToFolder     = { [weak self] img in self?.finish(with: img, action: .saveToFolder) }
        view.onCopyToClipboard  = { [weak self] img in self?.finish(with: img, action: .copyToClipboard) }
        view.onCancel           = { [weak self] in self?.finish(with: nil, action: .copyToClipboard) }
        view.onMoveSelection    = { [weak self] newRect in self?.captureAndAnnotate(selectionRect: newRect) }
        contentView = view
        makeFirstResponder(view)
    }

    private func finish(with image: NSImage?, action: CaptureAction) {
        NSCursor.arrow.set()
        let cb = completion
        CaptureOverlayWindow.activeWindow = nil
        orderOut(nil)
        cb?(image, action)
    }

    private func showPermissionAlert() {
        finish(with: nil, action: .copyToClipboard)
        let a = NSAlert()
        a.messageText = "Screen Recording Permission Required"
        a.informativeText = "1. Open System Settings → Privacy & Security → Screen Recording\n2. Toggle ScreenshotApp ON (off then on if already listed)\n3. Quit and relaunch the app, then try again."
        a.addButton(withTitle: "Open Settings"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

// MARK: - Selection View  (Phase 1)

// Uses Core Animation layers exclusively for drawing — no draw() override.
// This eliminates flickering that occurred with NSView.draw() because the
// dark overlay + transparent hole were recomposited on every mouse-move frame.
// CAShapeLayer.evenOdd fill rule punches the hole atomically; CATransaction
// with disableActions=true applies every update in a single compositing pass.
class SelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel:    (() -> Void)?

    private enum State {
        case idle
        case drawing(start: CGPoint)
        case placed(rect: CGRect)
        case dragging(anchor: CGPoint, original: CGRect)
    }
    private var state: State = .idle
    private var mouse: CGPoint = .zero
    private var captureTimer: Timer?

    // CA layers — all drawing is done here; no needsDisplay / draw() needed.
    private let frameLayer  = CAShapeLayer()   // dark overlay + evenOdd hole
    private let borderLayer = CAShapeLayer()   // selection border
    private let labelLayer  = CATextLayer()    // "W × H" size badge while drawing
    private var handleLayers: [CALayer] = []

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor

        let scale = window?.backingScaleFactor ?? 2.0

        // Dark overlay with an evenOdd hole for the selection.
        frameLayer.fillColor   = NSColor.black.withAlphaComponent(0.45).cgColor
        frameLayer.fillRule    = .evenOdd
        frameLayer.strokeColor = nil
        frameLayer.frame       = bounds
        layer?.addSublayer(frameLayer)

        // Selection border (white, optionally dashed)
        borderLayer.fillColor   = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth   = 1.5
        borderLayer.frame       = bounds
        layer?.addSublayer(borderLayer)

        // Size badge — shown only while actively drawing
        labelLayer.font            = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        labelLayer.fontSize        = 11
        labelLayer.foregroundColor = NSColor.white.cgColor
        labelLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        labelLayer.contentsScale   = scale
        labelLayer.alignmentMode   = .center
        labelLayer.isHidden        = true
        layer?.addSublayer(labelLayer)

        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
        updateLayers()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    override func mouseDown(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        captureTimer?.invalidate(); captureTimer = nil
        if case .placed(let r) = state, r.contains(mouse) {
            state = .dragging(anchor: mouse, original: r)
            NSCursor.closedHand.set()
        } else {
            state = .drawing(start: mouse)
            NSCursor.crosshair.set()
        }
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        switch state {
        case .drawing(let start):
            let r = makeRect(start, mouse)
            if r.width > 5 && r.height > 5 {
                state = .placed(rect: r)
                scheduleCapture(r)
            } else {
                state = .idle
            }
        case .dragging(let anchor, let original):
            let moved = original.offsetBy(dx: mouse.x - anchor.x, dy: mouse.y - anchor.y)
            state = .placed(rect: moved)
            NSCursor.openHand.set()
            scheduleCapture(moved)
        default: break
        }
        updateLayers()
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if case .placed(let r) = state {
            (r.contains(pt) ? NSCursor.openHand : NSCursor.crosshair).set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // Swallow scroll and gesture events so they don't pass through to the
    // underlying app (e.g. a browser) and scroll the page while the user
    // is drawing a selection.
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}

    private func scheduleCapture(_ rect: CGRect) {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, case .placed = self.state else { return }
            self.captureTimer = nil
            self.onSelection?(rect)
        }
    }

    // MARK: Layer updates (called instead of needsDisplay = true)

    private func updateLayers() {
        guard let root = layer else { return }
        let b = root.bounds

        // Compute the current selection rectangle.
        let sr: CGRect?
        switch state {
        case .idle:                                sr = nil
        case .drawing(let s):
            let r = makeRect(s, mouse)
            sr = (r.width > 2 && r.height > 2) ? r : nil
        case .placed(let r):                       sr = r
        case .dragging(let a, let orig):
            sr = orig.offsetBy(dx: mouse.x - a.x, dy: mouse.y - a.y)
        }

        // All layer mutations in one CA transaction — no implicit animations,
        // no intermediate frames, so no flicker.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Frame: full-screen dark rect with evenOdd hole for the selection.
        let fp = CGMutablePath()
        fp.addRect(b)
        if let sr { fp.addRect(sr) }
        frameLayer.path = fp

        guard let sr else {
            borderLayer.isHidden = true
            borderLayer.path = nil
            clearHandles()
            labelLayer.isHidden = true
            return
        }

        // Border
        borderLayer.path    = CGPath(rect: sr, transform: nil)
        borderLayer.isHidden = false
        switch state {
        case .placed, .dragging:
            borderLayer.lineDashPattern = [6, 3]
        default:
            borderLayer.lineDashPattern = nil
        }

        // Handles (placed / dragging only)
        switch state {
        case .placed, .dragging:
            setHandles(for: sr, in: root)
            labelLayer.isHidden = true
        case .drawing(let s):
            clearHandles()
            // Size badge just above the top-right of the growing selection.
            let label = "\(Int(abs(mouse.x - s.x))) × \(Int(abs(mouse.y - s.y)))"
            let lw: CGFloat = 114
            let lx = max(sr.minX, min(sr.maxX - lw - 4, b.maxX - lw - 4))
            labelLayer.string  = label
            labelLayer.frame   = CGRect(x: lx, y: sr.maxY + 4, width: lw, height: 16)
            labelLayer.isHidden = false
        default:
            clearHandles()
            labelLayer.isHidden = true
        }
    }

    private func setHandles(for r: CGRect, in root: CALayer) {
        clearHandles()
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let h = CALayer()
            h.frame           = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            h.cornerRadius    = 4
            h.backgroundColor = NSColor.white.cgColor
            root.addSublayer(h)
            handleLayers.append(h)
        }
    }

    private func clearHandles() {
        handleLayers.forEach { $0.removeFromSuperlayer() }
        handleLayers.removeAll()
    }

    private func makeRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }
}

// MARK: - Annotation View  (Phase 2)

class AnnotationView: NSView {
    var onSaveToFolder:    ((NSImage) -> Void)?
    var onCopyToClipboard: ((NSImage) -> Void)?
    var onCancel:          (() -> Void)?
    /// Called when the user drags with the move tool — window re-captures at new rect.
    var onMoveSelection:   ((CGRect) -> Void)?

    private let image:        NSImage
    private var selectionRect: CGRect
    private let cgImageRef:   CGImage?
    private let pixelScaleX:  CGFloat
    private let pixelScaleY:  CGFloat

    private var drawActions:    [DrawAction] = []
    private var cachedBlurImg:  NSImage?        // cached blurred NSImage for blur-tool preview
    private var dragStart:      CGPoint?
    private var dragCurrent:    CGPoint?

    // Move-tool drag state
    private var moveDragAnchor:  CGPoint?
    private var moveDragOffset:  CGPoint = .zero

    // Resize-handle drag state
    private var resizeHandle:     ResizeHandle?
    private var resizeDragStart:  CGPoint = .zero
    private var resizeStartRect:  CGRect  = .zero
    private var resizeLiveRect:   CGRect  = .zero

    // Tool state — shared with panel
    var currentTool:  DrawTool = .move
    var currentColor: NSColor  = NSColor(red: 1, green: 0.22, blue: 0.22, alpha: 1)
    var strokeWidth:  CGFloat  = 3
    var blurRadius:   CGFloat  = 20

    private weak var toolPanel: AnnotationToolPanel?

    init(frame: NSRect, image: NSImage, selectionRect: CGRect) {
        self.image = image
        self.selectionRect = selectionRect
        // Extract the CGImage directly from the NSBitmapImageRep so we always
        // get the full pixel-resolution image (e.g. 1920×1006 for a 960×503
        // logical selection on a 2× display).  cgImage(forProposedRect:nil)
        // can silently downscale to 1× when context is nil, making pixelScale
        // wrong and breaking blur region placement + final-image rendering.
        let cg = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first?.cgImage
               ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cgImageRef = cg
        if let cg = cg {
            pixelScaleX = CGFloat(cg.width)  / selectionRect.width
            pixelScaleY = CGFloat(cg.height) / selectionRect.height
        } else { pixelScaleX = 1; pixelScaleY = 1 }
        // Restore saved tool sizes
        if let r = UserDefaults.standard.object(forKey: "blurRadius")  as? Double { blurRadius  = CGFloat(r) }
        if let w = UserDefaults.standard.object(forKey: "strokeWidth") as? Double { strokeWidth = CGFloat(w) }
        super.init(frame: frame)
        wantsLayer = true; layer?.isOpaque = false
        setupToolPanel()
        toolPanel?.updateSize(blurRadius, isBrightRadius: true)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NSCursor.openHand.set()
    }

    override func resetCursorRects() {
        if currentTool == .move {
            addCursorRect(selectionRect, cursor: .openHand)
            for (rect, handle) in handleRects() {
                addCursorRect(rect, cursor: cursorFor(handle))
            }
        } else {
            addCursorRect(selectionRect, cursor: .crosshair)
        }
    }

    // MARK: Tool panel

    private func setupToolPanel() {
        let panelW: CGFloat = 622
        let panelH: CGFloat = 44
        var px = selectionRect.maxX - panelW
        var py = selectionRect.maxY + 8
        px = max(4, min(px, bounds.width  - panelW - 4))
        if py + panelH > bounds.height - 4 { py = selectionRect.minY - panelH - 8 }
        py = max(4, py)

        let panel = AnnotationToolPanel(frame: NSRect(x: px, y: py, width: panelW, height: panelH))
        panel.onToolChanged    = { [weak self] t  in
            self?.currentTool = t; self?.needsDisplay = true
            self?.window?.invalidateCursorRects(for: self!)
            (t == .move ? NSCursor.openHand : NSCursor.crosshair).set()
            self?.window?.makeFirstResponder(self)
        }
        panel.onColorChanged   = { [weak self] c  in
            self?.currentColor = c
            self?.window?.makeFirstResponder(self)
        }
        panel.onUndo           = { [weak self] in  self?.undoLast();   self?.window?.makeFirstResponder(self) }
        panel.onSaveToFolder    = { [weak self] in  self?.doSaveToFolder() }
        panel.onCopyToClipboard = { [weak self] in  self?.doCopyToClipboard() }
        panel.onCancel          = { [weak self] in  self?.onCancel?() }
        addSubview(panel)
        toolPanel = panel
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Move drag: transparent — actual screen shows through the cleared hole
        if let _ = moveDragAnchor {
            let newRect = selectionRect.offsetBy(dx: moveDragOffset.x, dy: moveDragOffset.y)
                .intersection(bounds)
            drawTransparentPreview(rect: newRect, in: ctx)
            return
        }

        // Resize drag: transparent preview of new rect
        if resizeHandle != nil {
            drawTransparentPreview(rect: resizeLiveRect.intersection(bounds), in: ctx)
            return
        }

        // 1. Dark overlay everywhere
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: bounds).fill()

        // 2. Punch a transparent hole — the REAL screen shows through, pixel-perfect.
        //    We never draw the captured screenshot as a background in the preview.
        ctx.saveGState(); ctx.setBlendMode(.clear); ctx.fill(selectionRect); ctx.restoreGState()

        // 3. Blur regions: draw the blurred image clipped to each blur action's rect.
        //    (Everything outside blur rects stays transparent = live screen content.)
        let blurActions = drawActions.filter { if case .blur = $0.shape { return true }; return false }
        if !blurActions.isEmpty {
            if cachedBlurImg == nil, let cg = cgImageRef, let blurCG = applyBlurCI(cg) {
                // Wrap in NSImage so draw(in:) handles AppKit Y-axis conventions correctly.
                // Using ctx.draw(cgImage) with a manual translate+scaleBy(-1) flip is
                // unreliable: the direction depends on whether the CGImage came from a
                // Y-up or Y-down source and whether the backing context is flipped.
                // NSImage.draw(in:) always produces a visually correct result.
                let rep = NSBitmapImageRep(cgImage: blurCG)
                rep.size = selectionRect.size
                let img = NSImage(size: selectionRect.size)
                img.addRepresentation(rep)
                cachedBlurImg = img
            }
            if let blurImg = cachedBlurImg {
                for action in drawActions {
                    guard case .blur = action.shape else { continue }
                    let blurViewRect = makeRectFromPoints(action.start, action.end).intersection(selectionRect)
                    guard !blurViewRect.isEmpty else { continue }
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: blurViewRect).setClip()
                    blurImg.draw(in: selectionRect)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }

        // 4. Non-blur shapes, clipped to selection
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selectionRect).setClip()
        for action in drawActions {
            if case .blur = action.shape { continue }
            renderShape(action.shape, from: action.start, to: action.end)
        }
        // 5. In-progress shape preview
        if let s = dragStart, let e = dragCurrent, let previewShape = makeCurrentShape(from: s, to: e) {
            let alphaCtx = NSGraphicsContext.current!.cgContext
            alphaCtx.setAlpha(0.75)
            renderShape(previewShape, from: s, to: e)
            alphaCtx.setAlpha(1)
        }
        NSGraphicsContext.restoreGraphicsState()

        // 6. Selection dashed border
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 1.5; border.setLineDash([6, 3], count: 2, phase: 0); border.stroke()

        // 7. Resize handles (only in move mode)
        if currentTool == .move { drawHandles() }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if currentTool == .move {
            // Check resize handles first (higher priority than move)
            for (rect, handle) in handleRects() {
                if rect.insetBy(dx: -3, dy: -3).contains(pt) {
                    resizeHandle    = handle
                    resizeDragStart = pt
                    resizeStartRect = selectionRect
                    resizeLiveRect  = selectionRect
                    cursorFor(handle).set()
                    return
                }
            }
            // Interior → move
            guard selectionRect.contains(pt) else { return }
            moveDragAnchor = pt; moveDragOffset = .zero
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        guard selectionRect.contains(pt) else { return }
        dragStart = pt; dragCurrent = pt; needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let handle = resizeHandle {
            let delta = CGPoint(x: pt.x - resizeDragStart.x, y: pt.y - resizeDragStart.y)
            resizeLiveRect = applyResize(delta: delta, to: resizeStartRect, handle: handle)
                .intersection(bounds)
            needsDisplay = true
            return
        }
        if let anchor = moveDragAnchor {
            moveDragOffset = CGPoint(x: pt.x - anchor.x, y: pt.y - anchor.y)
            needsDisplay = true
            return
        }
        guard dragStart != nil else { return }
        dragCurrent = pt; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if resizeHandle != nil {
            resizeHandle = nil
            let finalRect = resizeLiveRect
            NSCursor.openHand.set()
            if finalRect.width > 10 && finalRect.height > 10 {
                onMoveSelection?(finalRect)
            }
            return
        }
        if let anchor = moveDragAnchor {
            let pt = convert(event.locationInWindow, from: nil)
            let offset = CGPoint(x: pt.x - anchor.x, y: pt.y - anchor.y)
            moveDragAnchor = nil; moveDragOffset = .zero
            NSCursor.openHand.set()
            if abs(offset.x) > 2 || abs(offset.y) > 2 {
                let newRect = selectionRect.offsetBy(dx: offset.x, dy: offset.y).intersection(bounds)
                if newRect.width > 10 && newRect.height > 10 { onMoveSelection?(newRect) }
            }
            return
        }
        guard let s = dragStart else { return }
        let e = convert(event.locationInWindow, from: nil)
        dragStart = nil; dragCurrent = nil
        let r = makeRectFromPoints(s, e).intersection(selectionRect)
        if r.width > 3 || r.height > 3 {
            if let shape = makeCurrentShape(from: s, to: e) {
                drawActions.append(DrawAction(shape: shape, start: s, end: e))
                if case .blur = shape { cachedBlurImg = nil }
            }
        }
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()    // ESC → back to selection
        case 51: undoLast()     // Delete / Backspace
        case 36: doCopyToClipboard()    // Return → copy to clipboard
        case 6:                 // Z — Cmd+Z or Ctrl+Z → undo
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.command) || mods.contains(.control) { undoLast() }
        default: break
        }
    }

    // MARK: Scroll wheel — resize current tool

    override func scrollWheel(with event: NSEvent) {
        guard currentTool != .move else { return }
        let delta = event.deltaY   // positive = scroll up = increase
        if currentTool == .blur {
            blurRadius = max(5, min(50, blurRadius + delta))
            cachedBlurImg = nil
            toolPanel?.updateSize(blurRadius, isBrightRadius: true)
            UserDefaults.standard.set(Double(blurRadius), forKey: "blurRadius")
        } else {
            strokeWidth = max(1, min(30, strokeWidth + delta * 0.5))
            toolPanel?.updateSize(strokeWidth, isBrightRadius: false)
            UserDefaults.standard.set(Double(strokeWidth), forKey: "strokeWidth")
        }
        needsDisplay = true
    }

    // MARK: Actions

    private func undoLast() {
        guard !drawActions.isEmpty else { return }
        let removed = drawActions.removeLast()
        if case .blur = removed.shape { cachedBlurImg = nil }
        needsDisplay = true
    }

    private func doSaveToFolder() {
        onSaveToFolder?(buildFinalImage() ?? image)
    }

    private func doCopyToClipboard() {
        onCopyToClipboard?(buildFinalImage() ?? image)
    }

    /// Enter key default: copy to clipboard.
    func triggerCopy() { doCopyToClipboard() }

    // MARK: Resize / Move helpers

    /// 8 handle rects in view space, aligned to the current selectionRect.
    private func handleRects() -> [(CGRect, ResizeHandle)] {
        let s = selectionRect; let h: CGFloat = 9; let hh = h / 2
        return [
            (CGRect(x: s.minX-hh, y: s.maxY-hh, width: h, height: h), .topLeft),
            (CGRect(x: s.midX-hh, y: s.maxY-hh, width: h, height: h), .top),
            (CGRect(x: s.maxX-hh, y: s.maxY-hh, width: h, height: h), .topRight),
            (CGRect(x: s.maxX-hh, y: s.midY-hh, width: h, height: h), .right),
            (CGRect(x: s.maxX-hh, y: s.minY-hh, width: h, height: h), .bottomRight),
            (CGRect(x: s.midX-hh, y: s.minY-hh, width: h, height: h), .bottom),
            (CGRect(x: s.minX-hh, y: s.minY-hh, width: h, height: h), .bottomLeft),
            (CGRect(x: s.minX-hh, y: s.midY-hh, width: h, height: h), .left),
        ]
    }

    private func cursorFor(_ handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default:            return .crosshair
        }
    }

    /// Compute a resized rect given a handle and a drag delta.
    private func applyResize(delta: CGPoint, to r: CGRect, handle: ResizeHandle) -> CGRect {
        var n = r; let minW: CGFloat = 30, minH: CGFloat = 30
        switch handle {
        case .top:
            n.size.height = max(minH, r.height + delta.y)
        case .bottom:
            n.origin.y    = min(r.minY + delta.y, r.maxY - minH)
            n.size.height = r.maxY - n.origin.y
        case .left:
            n.origin.x   = min(r.minX + delta.x, r.maxX - minW)
            n.size.width = r.maxX - n.origin.x
        case .right:
            n.size.width = max(minW, r.width + delta.x)
        case .topLeft:
            n.size.height = max(minH, r.height + delta.y)
            n.origin.x   = min(r.minX + delta.x, r.maxX - minW)
            n.size.width = r.maxX - n.origin.x
        case .topRight:
            n.size.height = max(minH, r.height + delta.y)
            n.size.width  = max(minW, r.width  + delta.x)
        case .bottomLeft:
            n.origin.y    = min(r.minY + delta.y, r.maxY - minH)
            n.size.height = r.maxY - n.origin.y
            n.origin.x   = min(r.minX + delta.x, r.maxX - minW)
            n.size.width = r.maxX - n.origin.x
        case .bottomRight:
            n.origin.y    = min(r.minY + delta.y, r.maxY - minH)
            n.size.height = r.maxY - n.origin.y
            n.size.width  = max(minW, r.width  + delta.x)
        }
        return n
    }

    /// Dark overlay with a transparent hole — actual screen shows through.
    private func drawTransparentPreview(rect: CGRect, in ctx: CGContext) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: bounds).fill()
        ctx.saveGState(); ctx.setBlendMode(.clear); ctx.fill(rect); ctx.restoreGState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let b = NSBezierPath(rect: rect)
        b.lineWidth = 1.5; b.setLineDash([6, 3], count: 2, phase: 0); b.stroke()
        // Size badge
        let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .backgroundColor: NSColor.black.withAlphaComponent(0.55)
        ]
        let astr = NSAttributedString(string: label, attributes: attrs)
        let sz = astr.size()
        astr.draw(at: CGPoint(x: rect.maxX - sz.width - 4, y: rect.maxY + 4))
    }

    /// White squares with a subtle shadow for resize handles.
    private func drawHandles() {
        for (rect, _) in handleRects() {
            let p = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            NSColor(white: 0.0, alpha: 0.25).setFill(); p.fill()   // thin shadow
            let inner = rect.insetBy(dx: 1, dy: 1)
            let pi = NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill(); pi.fill()
        }
    }

    // MARK: Shape helpers

    private func makeCurrentShape(from s: CGPoint, to e: CGPoint) -> DrawAction.Shape? {
        switch currentTool {
        case .move:      return nil
        case .blur:      return .blur
        case .rectangle: return .rectangle(color: currentColor, lineWidth: strokeWidth)
        case .ellipse:   return .ellipse(color: currentColor, lineWidth: strokeWidth)
        case .line:      return .line(color: currentColor, lineWidth: strokeWidth)
        case .arrow:     return .arrow(color: currentColor, lineWidth: strokeWidth)
        }
    }

    /// Draw a shape in the CURRENT NSGraphicsContext (view-space or lockFocus-space).
    private func renderShape(_ shape: DrawAction.Shape, from s: CGPoint, to e: CGPoint) {
        switch shape {
        case .blur:
            let r = makeRectFromPoints(s, e)
            // Translucent fill so the user sees the blur region extent.
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: r).fill()
            // Dark outer border — visible on white/light backgrounds.
            let outer = NSBezierPath(rect: r)
            outer.lineWidth = 3.0
            NSColor.black.withAlphaComponent(0.55).setStroke()
            outer.stroke()
            // White dashed inner border — visible on dark backgrounds.
            let inner = NSBezierPath(rect: r)
            inner.lineWidth = 1.5
            inner.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            inner.stroke()

        case .rectangle(let color, let width):
            color.setStroke()
            let p = NSBezierPath(rect: makeRectFromPoints(s, e))
            p.lineWidth = width; p.lineJoinStyle = .round; p.stroke()

        case .ellipse(let color, let width):
            color.setStroke()
            let p = NSBezierPath(ovalIn: makeRectFromPoints(s, e))
            p.lineWidth = width; p.stroke()

        case .line(let color, let width):
            color.setStroke()
            let p = NSBezierPath(); p.lineWidth = width; p.lineCapStyle = .round
            p.move(to: s); p.line(to: e); p.stroke()

        case .arrow(let color, let width):
            renderArrow(from: s, to: e, color: color, width: width)
        }
    }

    private func renderArrow(from s: CGPoint, to e: CGPoint, color: NSColor, width: CGFloat) {
        let dx = e.x - s.x, dy = e.y - s.y
        let len = sqrt(dx*dx + dy*dy)
        guard len > 1 else { return }
        let ux = dx/len, uy = dy/len
        let headLen = min(len * 0.38, max(10, width * 4))
        let headW   = headLen * 0.65
        let shaftEnd = CGPoint(x: e.x - ux * headLen, y: e.y - uy * headLen)

        color.setStroke(); color.setFill()

        let shaft = NSBezierPath(); shaft.lineWidth = width; shaft.lineCapStyle = .round
        shaft.move(to: s); shaft.line(to: shaftEnd); shaft.stroke()

        let px = -uy * headW/2, py = ux * headW/2
        let head = NSBezierPath()
        head.move(to: e)
        head.line(to: CGPoint(x: shaftEnd.x + px, y: shaftEnd.y + py))
        head.line(to: CGPoint(x: shaftEnd.x - px, y: shaftEnd.y - py))
        head.close(); head.fill()
    }

    // MARK: Final image rendering

    private func buildFinalImage() -> NSImage? {
        guard let cgOrig = cgImageRef else { return nil }

        let hasBlur   = drawActions.contains { if case .blur = $0.shape { return true }; return false }
        let shapeActs = drawActions.filter   { if case .blur = $0.shape { return false }; return true }

        // Resolve base (blurred or original) as a CGImage so we always stay at pixel resolution.
        let baseCG: CGImage
        if hasBlur {
            guard let blurredCG = applyBlurCI(cgOrig) else { return image }
            baseCG = blurredCG
        } else { baseCG = cgOrig }

        guard !shapeActs.isEmpty else {
            // No shapes — just return the (possibly blurred) image at full resolution.
            return NSImage(cgImage: baseCG, size: image.size)
        }

        // Create a CGContext at the ACTUAL pixel dimensions of the captured image.
        // On a 2× Retina display this is twice the logical point size, giving full sharpness.
        let pw = baseCG.width, ph = baseCG.height
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        // Draw the base image.
        ctx.draw(baseCG, in: CGRect(x: 0, y: 0, width: pw, height: ph))

        // Wrap in NSGraphicsContext so NSBezierPath works, then scale from
        // logical-point space (view coords) to pixel space via pixelScaleX/Y.
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: pixelScaleX, y: pixelScaleY)

        for action in shapeActs {
            // Subtract selection origin → image-local point coordinates.
            let s = CGPoint(x: action.start.x - selectionRect.origin.x,
                           y: action.start.y - selectionRect.origin.y)
            let e = CGPoint(x: action.end.x   - selectionRect.origin.x,
                           y: action.end.y   - selectionRect.origin.y)
            renderShape(action.shape, from: s, to: e)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let resultCG = ctx.makeImage() else { return image }
        // Wrap in NSBitmapImageRep with the logical size so DPI = 72×scale is preserved
        // in the saved file and on the clipboard — same as the original captured image.
        let resultRep = NSBitmapImageRep(cgImage: resultCG)
        resultRep.size = image.size   // logical points
        let resultImg = NSImage(size: image.size)
        resultImg.addRepresentation(resultRep)
        return resultImg
    }


    private func applyBlurCI(_ cg: CGImage) -> CGImage? {
        let pixSz = CGSize(width: cg.width, height: cg.height)
        let ciCtx = CIContext()
        var result = CIImage(cgImage: cg)
        for action in drawActions {
            guard case .blur = action.shape else { continue }
            let vr = makeRectFromPoints(action.start, action.end).intersection(selectionRect)
            let ir = clampRect(viewToImageRect(vr), to: pixSz)
            guard ir.width > 0, ir.height > 0 else { continue }
            guard let bf = CIFilter(name: "CIGaussianBlur")   else { continue }
            bf.setValue(result.clampedToExtent(), forKey: kCIInputImageKey)
            bf.setValue(blurRadius, forKey: kCIInputRadiusKey)
            guard let bo = bf.outputImage else { continue }
            guard let cf = CIFilter(name: "CISourceOverCompositing") else { continue }
            cf.setValue(bo.cropped(to: ir), forKey: kCIInputImageKey)
            cf.setValue(result,             forKey: kCIInputBackgroundImageKey)
            if let out = cf.outputImage { result = out }
        }
        return ciCtx.createCGImage(result, from: CGRect(origin: .zero, size: pixSz))
    }

    /// Convert view-rect → CIImage pixel rect (both Y-up; just shift + scale).
    private func viewToImageRect(_ r: CGRect) -> CGRect {
        CGRect(x: (r.origin.x - selectionRect.origin.x) * pixelScaleX,
               y: (r.origin.y - selectionRect.origin.y) * pixelScaleY,
               width:  r.width  * pixelScaleX,
               height: r.height * pixelScaleY)
    }

    private func clampRect(_ r: CGRect, to sz: CGSize) -> CGRect {
        let x = max(0, r.origin.x), y = max(0, r.origin.y)
        return CGRect(x: x, y: y,
                      width:  min(r.width,  sz.width  - x),
                      height: min(r.height, sz.height - y))
    }

    private func makeRectFromPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }
}

// MARK: - Annotation Tool Panel

class AnnotationToolPanel: NSView {
    var onToolChanged:  ((DrawTool) -> Void)?
    var onColorChanged: ((NSColor)  -> Void)?
    var onUndo:           (() -> Void)?
    var onSaveToFolder:   (() -> Void)?
    var onCopyToClipboard:(() -> Void)?
    var onCancel:         (() -> Void)?

    private var toolButtons: [DrawTool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var sizeLabel: NSTextField!
    private var currentTool: DrawTool = .blur
    private var isBluringMode = true

    // Color palette
    private let palette: [NSColor] = [
        NSColor(red: 1,    green: 0.22, blue: 0.22, alpha: 1),   // red
        NSColor(red: 1,    green: 0.60, blue: 0.00, alpha: 1),   // orange
        NSColor(red: 1,    green: 0.90, blue: 0.00, alpha: 1),   // yellow
        NSColor(red: 0.27, green: 0.70, blue: 0.25, alpha: 1),   // green
        NSColor.white,                                             // white
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.90).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth  = 0.5
        layer?.borderColor  = NSColor.white.withAlphaComponent(0.18).cgColor
        setupControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupControls() {
        let h = bounds.height
        var x: CGFloat = 8

        // ── Tool buttons ──────────────────────────────────────────────────
        let tools: [(DrawTool, String, String)] = [
            (.move,      "↖",   "Move (M)"),
            (.blur,      "⬛",  "Blur (B)"),
            (.rectangle, "▭",   "Rectangle (R)"),
            (.ellipse,   "⬭",   "Ellipse (E)"),
            (.line,      "╱",   "Line (L)"),
            (.arrow,     "→",   "Arrow (A)"),
        ]
        for (tool, icon, tip) in tools {
            let btn = makeToolButton(icon, tip: tip, x: x)
            btn.tag = tool.rawValue
            btn.action = #selector(toolTapped(_:))
            toolButtons[tool] = btn
            x += 38
        }
        x += 4

        // ── Separator ─────────────────────────────────────────────────────
        addSeparator(at: x, height: h); x += 9

        // ── Size label ────────────────────────────────────────────────────
        let lbl = NSTextField(labelWithString: "20r")
        lbl.frame = NSRect(x: x, y: (h-16)/2, width: 36, height: 16)
        lbl.textColor = .white
        lbl.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        lbl.alignment = .left
        addSubview(lbl); sizeLabel = lbl; x += 42

        // ── Separator ─────────────────────────────────────────────────────
        addSeparator(at: x, height: h); x += 9

        // ── Color swatches ────────────────────────────────────────────────
        for (i, color) in palette.enumerated() {
            let btn = NSButton(frame: NSRect(x: x, y: (h-20)/2, width: 20, height: 20))
            btn.wantsLayer = true
            btn.isBordered = false
            btn.layer?.cornerRadius = 10
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.borderWidth = (i == 0) ? 2.5 : 1
            btn.layer?.borderColor = NSColor.white.withAlphaComponent((i == 0) ? 1 : 0.35).cgColor
            btn.tag = i
            btn.target = self; btn.action = #selector(colorTapped(_:))
            addSubview(btn); colorButtons.append(btn)
            x += 24
        }
        x += 4

        // ── Separator ─────────────────────────────────────────────────────
        addSeparator(at: x, height: h); x += 9

        // ── Action buttons ────────────────────────────────────────────────
        let undo   = makeIconButton("↺", tip: "Undo  ⌫", x: x);   undo.action   = #selector(undoTapped);        x += 32
        let cancel = makeIconButton("✕", tip: "Cancel  Esc", x: x); cancel.action = #selector(cancelTapped);    x += 32
        let saveFolderBtn = makeLabeledActionButton(sfSymbol: "square.and.arrow.down", title: "Save", tip: "Save to folder", x: x)
        saveFolderBtn.action = #selector(saveFolderTapped); x += 64
        let copyBtn = makeLabeledActionButton(sfSymbol: "doc.on.clipboard", title: "Copy", tip: "Copy to clipboard  ↩", x: x)
        copyBtn.action = #selector(copyTapped)
        copyBtn.contentTintColor = .systemGreen

        // Highlight the default tool (move)
        highlightTool(.move)
    }

    func updateSize(_ value: CGFloat, isBrightRadius: Bool) {
        let suffix = isBrightRadius ? "r" : "pt"
        sizeLabel.stringValue = "\(Int(value.rounded()))\(suffix)"
    }

    // MARK: Actions

    @objc private func toolTapped(_ btn: NSButton) {
        let tool = DrawTool(rawValue: btn.tag) ?? .move
        currentTool = tool
        highlightTool(tool)
        onToolChanged?(tool)
    }

    @objc private func colorTapped(_ btn: NSButton) {
        let color = palette[btn.tag]
        for (i, cb) in colorButtons.enumerated() {
            cb.layer?.borderWidth = (i == btn.tag) ? 2.5 : 1
            cb.layer?.borderColor = NSColor.white.withAlphaComponent((i == btn.tag) ? 1 : 0.35).cgColor
        }
        onColorChanged?(color)
    }

    @objc private func undoTapped()        { onUndo?()           }
    @objc private func cancelTapped()      { onCancel?()         }
    @objc private func saveFolderTapped()  { onSaveToFolder?()   }
    @objc private func copyTapped()        { onCopyToClipboard?() }

    private func highlightTool(_ tool: DrawTool) {
        for (t, btn) in toolButtons {
            let active = (t == tool)
            btn.wantsLayer = true
            btn.layer?.backgroundColor = active
                ? NSColor.white.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
            btn.layer?.cornerRadius = 6
        }
    }

    // MARK: Builders

    @discardableResult
    private func makeToolButton(_ icon: String, tip: String, x: CGFloat) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: (bounds.height-28)/2, width: 34, height: 28))
        btn.title = icon; btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 15)
        btn.contentTintColor = .white; btn.toolTip = tip; btn.target = self
        addSubview(btn); return btn
    }

    @discardableResult
    private func makeIconButton(_ icon: String, tip: String, x: CGFloat) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: (bounds.height-26)/2, width: 28, height: 26))
        btn.title = icon; btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 14)
        btn.contentTintColor = .white; btn.toolTip = tip; btn.target = self
        addSubview(btn); return btn
    }

    /// Flat labeled button with an SF Symbol on the left and a text title — used for Save / Copy.
    @discardableResult
    private func makeLabeledActionButton(sfSymbol: String, title: String, tip: String, x: CGFloat) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: (bounds.height-26)/2, width: 62, height: 26))
        btn.isBordered = false
        btn.imagePosition = .imageLeft
        btn.title = title
        btn.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        btn.contentTintColor = .white
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        btn.image = NSImage(systemSymbolName: sfSymbol, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        btn.toolTip = tip; btn.target = self
        addSubview(btn); return btn
    }

    private func addSeparator(at x: CGFloat, height h: CGFloat) {
        let sep = NSBox(frame: NSRect(x: x, y: 6, width: 1, height: h-12))
        sep.boxType = .separator; addSubview(sep)
    }

    // Block mouse events so clicks on the panel don't start a draw action behind it.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
