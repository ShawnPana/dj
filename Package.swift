// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dj",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "dj",
            path: "dj",
            resources: [
                .copy("../scripts/stem_server.py")
            ]
        )
    ]
)
