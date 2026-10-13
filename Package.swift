// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NathPaint",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NathPaint", targets: ["NathPaint"])],
    targets: [
        .target(name: "PaintCore", resources: [.process("Resources")]),
        .executableTarget(name: "NathPaint", dependencies: ["PaintCore"]),
        .testTarget(name: "PaintCoreTests", dependencies: ["PaintCore"])
    ],
    swiftLanguageModes: [.v5]
)
