// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NahtPaint",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NahtPaint", targets: ["NahtPaint"])],
    targets: [
        .target(name: "PaintCore", resources: [.process("Resources")]),
        .executableTarget(name: "NahtPaint", dependencies: ["PaintCore"]),
        .testTarget(name: "PaintCoreTests", dependencies: ["PaintCore"]),
        .testTarget(name: "NahtPaintTests", dependencies: ["NahtPaint"])
    ],
    swiftLanguageModes: [.v5]
)
