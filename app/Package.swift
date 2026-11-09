// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Crateyard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Crateyard", path: "Sources/Crateyard")
    ]
)
