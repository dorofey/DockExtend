// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockExtend",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DockExtend", targets: ["DockExtend"])
    ],
    targets: [
        .executableTarget(name: "DockExtend")
    ]
)
