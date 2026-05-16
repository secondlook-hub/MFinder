// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MFinder",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MFinder",
            path: "Sources/MFinder"
        )
    ]
)
