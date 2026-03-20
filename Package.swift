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
        .executable(name: "MonthlyVideoGeneratorApp", targets: ["MonthlyVideoGeneratorApp"]),
        .executable(name: "TitleTreatmentPreviewGenerator", targets: ["TitleTreatmentPreviewGenerator"])
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
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "TitleTreatmentPreviewGenerator",
            dependencies: ["Core"],
            path: "Sources/TitleTreatmentPreviewGenerator"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core", "PhotosIntegration", "MonthlyVideoGeneratorApp"],
            path: "Tests/CoreTests"
        )
    ]
)
