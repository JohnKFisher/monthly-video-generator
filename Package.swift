// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonthlyVideoGenerator",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "PhotosIntegration", targets: ["PhotosIntegration"]),
        .executable(name: "MonthlyVideoGeneratorApp", targets: ["MonthlyVideoGeneratorApp"])
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .target(
            name: "PhotosIntegration",
            dependencies: ["Core"],
            path: "Sources/Integrations/Photos"
        ),
        .executableTarget(
            name: "MonthlyVideoGeneratorApp",
            dependencies: ["Core", "PhotosIntegration"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "PhotosIntegration", "MonthlyVideoGeneratorApp"],
            path: "Tests/CoreTests"
        )
    ]
)
