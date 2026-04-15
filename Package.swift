// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenshotApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ScreenshotApp",
            path: "Sources/ScreenshotApp",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        )
    ]
)
