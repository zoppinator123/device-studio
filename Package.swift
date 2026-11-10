// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeviceStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DeviceStudio", targets: ["ControlCenter"])],
    targets: [
        .target(name: "CDeviceSupport", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .executableTarget(name: "ControlCenter", dependencies: ["CDeviceSupport"],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
