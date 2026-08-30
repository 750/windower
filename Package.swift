// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "windower",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "windower",
            swiftSettings: [
                // CLI + top-level C bridge code: keep Swift 5 language mode to
                // avoid strict-concurrency noise on the AX/CG C-API usage.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
