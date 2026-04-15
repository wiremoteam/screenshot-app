#!/usr/bin/swift
// Icon generator for ScreenshotApp.
// Run with:  swift gen_icon.swift
// Then:      iconutil -c icns /tmp/ScreenshotApp.iconset -o Resources/AppIcon.icns

import AppKit
import CoreGraphics

func makeIconRep(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high

    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()

    // ── 1. Rounded rect clip + gradient background ───────────────────────────
    let corner = s * 0.225
    let bgPath = CGPath(roundedRect: CGRect(x:0, y:0, width:s, height:s),
                        cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // Deep navy → near-black diagonal gradient
    let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [CGColor(red:0.075, green:0.090, blue:0.160, alpha:1),   // #13173A
                 CGColor(red:0.024, green:0.027, blue:0.055, alpha:1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: s*0.15, y: s*0.92),
                           end:   CGPoint(x: s*0.85, y: s*0.08),
                           options: [])

    // ── 2. Dashed selection rectangle ───────────────────────────────────────
    let pad: CGFloat = s * 0.155
    let sel = CGRect(x: pad, y: pad, width: s - pad*2, height: s - pad*2)

    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red:1, green:1, blue:1, alpha:0.78))
    ctx.setLineWidth(s * 0.026)
    ctx.setLineDash(phase: 0, lengths: [s*0.088, s*0.048])
    ctx.stroke(sel)
    ctx.restoreGState()

    // ── 3. Corner L-handles in electric blue ────────────────────────────────
    let hl: CGFloat = s * 0.135     // arm length
    let hw: CGFloat = s * 0.038     // stroke width
    let blue = CGColor(red:0.275, green:0.565, blue:0.980, alpha:1)   // #469BFA

    ctx.saveGState()
    ctx.setStrokeColor(blue)
    ctx.setLineWidth(hw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Bottom-left
    ctx.move(to: CGPoint(x: sel.minX + hl, y: sel.minY))
    ctx.addLine(to: CGPoint(x: sel.minX, y: sel.minY))
    ctx.addLine(to: CGPoint(x: sel.minX, y: sel.minY + hl))
    // Bottom-right
    ctx.move(to: CGPoint(x: sel.maxX - hl, y: sel.minY))
    ctx.addLine(to: CGPoint(x: sel.maxX, y: sel.minY))
    ctx.addLine(to: CGPoint(x: sel.maxX, y: sel.minY + hl))
    // Top-left
    ctx.move(to: CGPoint(x: sel.minX + hl, y: sel.maxY))
    ctx.addLine(to: CGPoint(x: sel.minX, y: sel.maxY))
    ctx.addLine(to: CGPoint(x: sel.minX, y: sel.maxY - hl))
    // Top-right
    ctx.move(to: CGPoint(x: sel.maxX - hl, y: sel.maxY))
    ctx.addLine(to: CGPoint(x: sel.maxX, y: sel.maxY))
    ctx.addLine(to: CGPoint(x: sel.maxX, y: sel.maxY - hl))
    ctx.strokePath()

    // Soft glow behind each handle (paint before the stroke above at the same path)
    // We add a wider blurry pass first
    ctx.setAlpha(0.30)
    ctx.setStrokeColor(blue)
    ctx.setLineWidth(hw * 3.5)
    // Bottom-left
    ctx.move(to: CGPoint(x: sel.minX + hl, y: sel.minY))
    ctx.addLine(to: CGPoint(x: sel.minX, y: sel.minY))
    ctx.addLine(to: CGPoint(x: sel.minX, y: sel.minY + hl))
    // Bottom-right
    ctx.move(to: CGPoint(x: sel.maxX - hl, y: sel.minY))
    ctx.addLine(to: CGPoint(x: sel.maxX, y: sel.minY))
    ctx.addLine(to: CGPoint(x: sel.maxX, y: sel.minY + hl))
    // Top-left
    ctx.move(to: CGPoint(x: sel.minX + hl, y: sel.maxY))
    ctx.addLine(to: CGPoint(x: sel.minX, y: sel.maxY))
    ctx.addLine(to: CGPoint(x: sel.minX, y: sel.maxY - hl))
    // Top-right
    ctx.move(to: CGPoint(x: sel.maxX - hl, y: sel.maxY))
    ctx.addLine(to: CGPoint(x: sel.maxX, y: sel.maxY))
    ctx.addLine(to: CGPoint(x: sel.maxX, y: sel.maxY - hl))
    ctx.strokePath()
    ctx.setAlpha(1.0)
    ctx.restoreGState()

    // ── 4. Blur region (bottom-right quadrant inside selection) ─────────────
    let brX = sel.minX + sel.width  * 0.43
    let brY = sel.minY + sel.height * 0.07
    let brW = sel.width  * 0.50
    let brH = sel.height * 0.41
    let blurRect = CGRect(x: brX, y: brY, width: brW, height: brH)

    ctx.saveGState()
    // Base frosted fill
    ctx.setFillColor(CGColor(red:0.275, green:0.565, blue:0.980, alpha:0.18))
    ctx.fill(blurRect)
    // Horizontal band layers to suggest blur stripes
    let bandAlphas: [CGFloat] = [0.05, 0.10, 0.04, 0.12, 0.05, 0.08]
    let bandH = brH / CGFloat(bandAlphas.count)
    for (i, alpha) in bandAlphas.enumerated() {
        let by = brY + CGFloat(i) * bandH
        ctx.setFillColor(CGColor(red:0.55, green:0.75, blue:1.0, alpha:alpha))
        ctx.fill(CGRect(x: brX + 1, y: by, width: brW - 2, height: bandH - 0.5))
    }
    // Frosted border
    ctx.setStrokeColor(CGColor(red:0.4, green:0.65, blue:1.0, alpha:0.55))
    ctx.setLineWidth(s * 0.014)
    ctx.stroke(blurRect)
    ctx.restoreGState()

    // ── 5. Crosshair cursor (centre of selection, slightly offset) ───────────
    let cx = sel.midX + sel.width  * 0.05
    let cy = sel.midY + sel.height * 0.09
    let cl = s * 0.052    // arm length
    let cg = s * 0.014    // centre gap
    let cw = s * 0.019    // stroke width

    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red:1, green:1, blue:1, alpha:0.80))
    ctx.setLineWidth(cw)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: cx - cl, y: cy)); ctx.addLine(to: CGPoint(x: cx - cg, y: cy))
    ctx.move(to: CGPoint(x: cx + cg, y: cy)); ctx.addLine(to: CGPoint(x: cx + cl, y: cy))
    ctx.move(to: CGPoint(x: cx, y: cy - cl)); ctx.addLine(to: CGPoint(x: cx, y: cy - cg))
    ctx.move(to: CGPoint(x: cx, y: cy + cg)); ctx.addLine(to: CGPoint(x: cx, y: cy + cl))
    ctx.strokePath()
    ctx.restoreGState()

    return rep
}

// ── Generate all required macOS icon sizes ────────────────────────────────────
let iconsetPath = "/tmp/ScreenshotApp.iconset"
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let specs: [(pt: Int, scale: Int)] = [
    (16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)
]
for spec in specs {
    let px = spec.pt * spec.scale
    let rep = makeIconRep(size: px)
    let data = rep.representation(using: .png, properties: [:])!
    let name = spec.scale == 1
        ? "icon_\(spec.pt)x\(spec.pt).png"
        : "icon_\(spec.pt)x\(spec.pt)@2x.png"
    try! data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    print("  ✓ \(name)  (\(px)×\(px)px)")
}
print("\nIconset written to \(iconsetPath)")
print("Run:  iconutil -c icns \(iconsetPath) -o Resources/AppIcon.icns")
