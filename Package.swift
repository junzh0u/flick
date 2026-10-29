// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Flick",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "FlickCore"),
        .executableTarget(name: "Flick", dependencies: ["FlickCore"]),
        .testTarget(name: "FlickCoreTests", dependencies: ["FlickCore"]),
    ]
)
