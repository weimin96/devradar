// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "pscan",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "pscan", targets: ["pscan-cli"]),
        .library(name: "PScanKit", targets: ["PScanKit"]),
    ],
    targets: [
        .target(name: "PScanKit"),
        .executableTarget(
            name: "pscan-cli",
            dependencies: ["PScanKit"]
        ),
    ]
)
