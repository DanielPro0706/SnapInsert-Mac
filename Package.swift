// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnapInsertCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SnapInsertCore", targets: ["SnapInsertCore"])],
    targets: [
        .target(name: "SnapInsertCore", path: "Shared"),
        .testTarget(name: "SnapInsertCoreTests", dependencies: ["SnapInsertCore"], path: "Tests/SnapInsertCoreTests")
    ]
)
