// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockExtend",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DockExtend", targets: ["DockExtend"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "DockExtend",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")]
        )
    ]
)
