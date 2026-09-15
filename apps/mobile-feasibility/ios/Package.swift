// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWhisprIOSFeasibilityCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "OpenWhisprIOSFeasibilityCore",
            targets: ["OpenWhisprIOSFeasibilityCore"]
        )
    ],
    targets: [
        .target(
            name: "OpenWhisprIOSFeasibilityCore",
            path: "Sources/Shared"
        ),
        .testTarget(
            name: "OpenWhisprIOSFeasibilityCoreTests",
            dependencies: ["OpenWhisprIOSFeasibilityCore"],
            path: "Tests/OpenWhisprIOSFeasibilityCoreTests"
        )
    ]
)
