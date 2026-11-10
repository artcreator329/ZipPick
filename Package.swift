// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZipPick",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ZipPick",
            path: "Sources/ZipPick",
            linkerSettings: [.linkedLibrary("z")]
        )
    ]
)
