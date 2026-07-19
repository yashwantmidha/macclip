// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macclip",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "macclip",
            path: "Sources/macclip"
        ),
        .testTarget(
            name: "macclipTests",
            dependencies: ["macclip"],
            path: "Tests/macclipTests"
        )
    ]
)
