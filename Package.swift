// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nomouse-helper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "mouseless-daemon", path: "Sources/mouseless-daemon"),
        .testTarget(name: "MouselessDaemonTests", dependencies: ["mouseless-daemon"], path: "Tests/MouselessDaemonTests"),
    ]
)
