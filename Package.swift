// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CamDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CamDesk", targets: ["CamDesk"])],
    targets: [.executableTarget(name: "CamDesk", path: "Sources", linkerSettings: [
        .linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("AVFoundation"),
        .linkedFramework("Security"), .linkedFramework("CryptoKit"), .linkedFramework("Network")
    ])]
)
