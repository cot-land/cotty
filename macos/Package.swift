// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Cotty",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .target(
            name: "CCottyCore",
            path: "Sources/CCottyCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Cotty",
            dependencies: ["CCottyCore"],
            path: "Sources/Cotty",
            linkerSettings: [
                .unsafeFlags([
                    "-L..",
                    "-lcotty",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../..",
                ]),
            ]
        ),
    ]
)
