// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceStudio",
    platforms: [.macOS("14.2")],   // meeting recording uses Core Audio process taps (14.2+)
    products: [.executable(name: "DeviceStudio", targets: ["ControlCenter"])],
    targets: [
        .target(name: "CDeviceSupport", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        // Two-channel meeting capture: microphone and system audio, one clock, encrypted spool.
        // No UI and no network; the app's Meetings page drives it.
        .target(name: "CaptureKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ControlCenter", dependencies: ["CDeviceSupport", "CaptureKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"], path: "Tests/CaptureKitTests",
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
