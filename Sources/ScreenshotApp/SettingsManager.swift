import Foundation
import AppKit

// Carbon modifier constants
let kCmdKey: Int = 1 << 8   // 256
let kShiftKey: Int = 1 << 9  // 512
let kOptionKey: Int = 1 << 11 // 2048
let kControlKey: Int = 1 << 12 // 4096

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("com.screenshotapp.hotkeyChanged")
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var savePath: String {
        didSet {
            UserDefaults.standard.set(savePath, forKey: "savePath")
            ensureSaveDirectoryExists()
        }
    }

    @Published var hotkeyKeyCode: Int {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }

    @Published var hotkeyModifiers: Int {
        didSet { UserDefaults.standard.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }

    @Published var imageFormat: String {
        didSet { UserDefaults.standard.set(imageFormat, forKey: "imageFormat") }
    }

    private init() {
        let defaultPath = (NSSearchPathForDirectoriesInDomains(
            .picturesDirectory, .userDomainMask, true
        ).first ?? NSHomeDirectory()) + "/Screenshots"

        self.savePath = UserDefaults.standard.string(forKey: "savePath") ?? defaultPath
        // Default hotkey: Ctrl+Shift+4 (keyCode 21 = '4' key)
        // Avoids conflict with macOS built-in Cmd+Shift+3/4 screenshot shortcuts
        self.hotkeyKeyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int ?? 21
        self.hotkeyModifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int
            ?? (kControlKey | kShiftKey)
        self.imageFormat = UserDefaults.standard.string(forKey: "imageFormat") ?? "png"
    }

    func ensureSaveDirectoryExists() {
        let url = URL(fileURLWithPath: savePath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var hotkeyDisplayString: String {
        let mods = hotkeyModifiers
        var parts: [String] = []
        if mods & kControlKey != 0 { parts.append("⌃") }
        if mods & kOptionKey != 0  { parts.append("⌥") }
        if mods & kShiftKey != 0   { parts.append("⇧") }
        if mods & kCmdKey != 0     { parts.append("⌘") }
        parts.append(SettingsManager.keyCodeToString(hotkeyKeyCode))
        return parts.joined()
    }

    static func keyCodeToString(_ keyCode: Int) -> String {
        let map: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}
