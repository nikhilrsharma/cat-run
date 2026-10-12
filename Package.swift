// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CatRun",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "KeepAwake", targets: ["KeepAwake"])],
    targets: [
        .target(name: "KeepAwakeCore"),
        .executableTarget(name: "KeepAwake", dependencies: ["KeepAwakeCore"]),
        .testTarget(name: "KeepAwakeCoreTests", dependencies: ["KeepAwakeCore"]),
        .testTarget(name: "KeepAwakeNativeTests", dependencies: ["KeepAwake"])
    ],
    swiftLanguageModes: [.v5]
)
