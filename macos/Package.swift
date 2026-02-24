// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Cotty",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "Cotty",
            path: "Sources/Cotty"
        ),
    ]
)
