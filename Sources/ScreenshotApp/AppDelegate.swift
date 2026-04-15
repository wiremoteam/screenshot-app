import AppKit
import CoreGraphics
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotkeyManager = HotkeyManager()
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsManager.shared.ensureSaveDirectoryExists()
        setupMenuBar()
        hotkeyManager.register { [weak self] in
            self?.takeScreenshot()
        }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        // Register as a login item on first launch.
        // The user can toggle it off via the menu item afterward.
        let firstLaunchKey = "launchAtLoginRegistered"
        if !UserDefaults.standard.bool(forKey: firstLaunchKey) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: firstLaunchKey)
        }
        updateLaunchAtLoginMenuItem()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.isVisible = true

        if let button = statusItem?.button {
            button.image = makeMenuBarIcon()
            button.toolTip = "ScreenshotApp"
        }

        let menu = NSMenu()

        let captureItem = NSMenuItem(
            title: "Take Screenshot  (\(SettingsManager.shared.hotkeyDisplayString))",
            action: #selector(takeScreenshot),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        launchAtLoginItem = loginItem
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit ScreenshotApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu

        NotificationCenter.default.addObserver(forName: .hotkeyChanged, object: nil, queue: .main) { _ in
            captureItem.title = "Take Screenshot  (\(SettingsManager.shared.hotkeyDisplayString))"
        }
    }

    /// Selection-rectangle icon: dashed border + filled corner handles.
    private func makeMenuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.5)

            // Dashed selection rectangle
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            ctx.stroke(CGRect(x: 2, y: 3.5, width: 14, height: 11))
            ctx.setLineDash(phase: 0, lengths: [])

            // Filled corner handles
            let hs: CGFloat = 3
            for (hx, hy): (CGFloat, CGFloat) in [(2, 3.5), (16, 3.5), (2, 14.5), (16, 14.5)] {
                ctx.fill(CGRect(x: hx - hs/2, y: hy - hs/2, width: hs, height: hs))
            }

            return true
        }
        img.isTemplate = true
        return img
    }

    @objc func takeScreenshot() {
        CaptureOverlayWindow.show { image, action in
            guard let image = image else { return }
            DispatchQueue.main.async {
                // Write to clipboard as a 144-DPI PNG so pasting into apps
                // (Slack, Notion, browsers) stays at Retina resolution.
                let pb = NSPasteboard.general
                pb.clearContents()
                if let rep = image.representations
                        .compactMap({ $0 as? NSBitmapImageRep }).first,
                   let png = rep.representation(using: .png, properties: [
                       .interlaced: false
                   ]) {
                    pb.setData(png, forType: .png)
                } else {
                    pb.writeObjects([image])
                }
                if action == .saveToFolder {
                    ImageSaver.save(image: image)
                }
            }
        }
    }

    @objc func openSettings() {
        SettingsWindowController.showSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        updateLaunchAtLoginMenuItem()
    }

    private func updateLaunchAtLoginMenuItem() {
        launchAtLoginItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }
}
