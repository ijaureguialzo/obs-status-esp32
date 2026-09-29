// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ObsStatus",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "obs-status",
            targets: ["ObsStatus"]
        )
    ],
    dependencies: [
        // WebSocket library (uncomment when choosing a library)
        // .package(url: "https://github.com/danielecoccha/Starscream.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ObsStatus",
            path: "Sources"
        )
    ]
)
