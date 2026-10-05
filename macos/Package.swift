// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GrokUsageBar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.1")
    ],
    targets: [
        .executableTarget(
            name: "GrokUsageBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/GrokUsageBar",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "GrokUsageBarTests",
            dependencies: ["GrokUsageBar"],
            path: "Tests/GrokUsageBarTests"
        )
    ]
)
