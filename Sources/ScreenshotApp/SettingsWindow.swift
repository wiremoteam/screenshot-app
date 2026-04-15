import AppKit
import SwiftUI

// MARK: - Settings Window Controller

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func showSettings() {
        if shared == nil {
            shared = SettingsWindowController()
        }
        shared?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenshotApp Settings"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        let hostingView = NSHostingView(rootView: SettingsView())
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        SettingsWindowController.shared = nil
    }
}

// MARK: - SwiftUI Settings View

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isRecordingHotkey = false

    var body: some View {
        VStack(spacing: 0) {
            // Save Location
            GroupBox(label: Label("Save Location", systemImage: "folder")) {
                HStack {
                    Text(settings.savePath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Choose…") { chooseSavePath() }
                        .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            .padding([.horizontal, .top], 16)

            // Hotkey
            GroupBox(label: Label("Screenshot Hotkey", systemImage: "keyboard")) {
                HStack {
                    if isRecordingHotkey {
                        Text("Press your hotkey combination…")
                            .foregroundColor(.orange)
                    } else {
                        Text(settings.hotkeyDisplayString)
                            .font(.system(.title3, design: .monospaced))
                            .bold()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                    }
                    Spacer()
                    Button(isRecordingHotkey ? "Cancel" : "Change") {
                        isRecordingHotkey.toggle()
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
                .background(
                    HotkeyCapture(isActive: isRecordingHotkey) { keyCode, modifiers in
                        settings.hotkeyKeyCode = keyCode
                        settings.hotkeyModifiers = modifiers
                        isRecordingHotkey = false
                        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                    }
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Image Format
            GroupBox(label: Label("Image Format", systemImage: "photo")) {
                Picker("", selection: $settings.imageFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            Text("Default hotkey: ⌃⇧4  (doesn't conflict with macOS screenshots)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 12)
        }
        .frame(width: 480, height: 280)
    }

    private func chooseSavePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder where screenshots will be saved"
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            settings.savePath = url.path
        }
    }
}

// MARK: - Hotkey Capture (NSViewRepresentable)

struct HotkeyCapture: NSViewRepresentable {
    var isActive: Bool
    var onHotkey: (Int, Int) -> Void

    func makeNSView(context: Context) -> HotkeyCaptureView {
        HotkeyCaptureView(onHotkey: onHotkey)
    }

    func updateNSView(_ nsView: HotkeyCaptureView, context: Context) {
        nsView.isActive = isActive
        if isActive {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

class HotkeyCaptureView: NSView {
    var isActive = false
    var onHotkey: (Int, Int) -> Void

    init(onHotkey: @escaping (Int, Int) -> Void) {
        self.onHotkey = onHotkey
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isActive else { super.keyDown(with: event); return }

        // Ignore lone modifier keys
        let code = Int(event.keyCode)
        guard ![54, 55, 56, 57, 58, 59, 60, 63].contains(code) else { return }

        var mods = 0
        if event.modifierFlags.contains(.command)  { mods |= kCmdKey }
        if event.modifierFlags.contains(.shift)    { mods |= kShiftKey }
        if event.modifierFlags.contains(.option)   { mods |= kOptionKey }
        if event.modifierFlags.contains(.control)  { mods |= kControlKey }

        isActive = false
        onHotkey(code, mods)
    }
}
