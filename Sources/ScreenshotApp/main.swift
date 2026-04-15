import AppKit

// Must be set before run() — setting it in applicationDidFinishLaunching is too late
// and the Dock icon still flashes briefly.
NSApplication.shared.setActivationPolicy(.accessory)

private let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
