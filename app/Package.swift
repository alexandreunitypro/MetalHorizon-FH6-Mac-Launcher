// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetalHorizon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MetalHorizon", targets: ["MetalHorizon"])
    ],
    targets: [
        .executableTarget(name: "MetalHorizon"),
        .testTarget(name: "MetalHorizonTests", dependencies: ["MetalHorizon"])
    ]
)
