import AppKit

struct ImageSaver {
    private static var lastSavedURL: URL?

    /// Saves the image to the configured folder. Returns true on success.
    /// Also reveals the file in Finder on first save.
    @discardableResult
    static func save(image: NSImage, revealInFinder: Bool = true) -> Bool {
        let settings = SettingsManager.shared
        settings.ensureSaveDirectoryExists()

        let dir = URL(fileURLWithPath: settings.savePath)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())

        let fmt = settings.imageFormat
        let ext = fmt == "jpeg" ? "jpg" : "png"
        let url = dir.appendingPathComponent("Screenshot_\(timestamp).\(ext)")

        // Prefer the raw bitmap rep so we always get the full Retina pixel resolution.
        let cgImage: CGImage
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           let cg = rep.cgImage {
            cgImage = cg
        } else if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cgImage = cg
        } else {
            showError("Failed to process image for saving.")
            return false
        }

        let uti: CFString = (fmt == "jpeg" ? "public.jpeg" : "public.png") as CFString

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            showError("Could not write to:\n\(url.path)\n\nCheck the folder exists and you have write permission.")
            return false
        }

        // Derive DPI from the image's own pixel/point ratio — correct for any display
        // scaling mode (standard 2×, "More Space" ~1.68×, non-Retina 1×, etc.).
        let dpi: Double
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.size.width > 0 {
            dpi = 72.0 * Double(rep.pixelsWide) / rep.size.width
        } else {
            dpi = 144.0
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth:  dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if fmt == "jpeg" {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            showError("Failed to write image to:\n\(url.path)")
            return false
        }

        lastSavedURL = url

        if revealInFinder {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return true
    }

    /// Deletes the last auto-saved file (used by Discard button).
    static func deleteLast() {
        guard let url = lastSavedURL else { return }
        try? FileManager.default.removeItem(at: url)
        lastSavedURL = nil
    }

    private static func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Save Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
