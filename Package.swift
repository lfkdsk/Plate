// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Plate",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        .library(name: "PlateCore", targets: ["PlateCore"]),
        .executable(name: "plate-cli", targets: ["PlateCLI"])
    ],
    targets: [
        .target(
            name: "PlateCore",
            path: "Sources/PlateCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "PlateCLI",
            dependencies: ["PlateCore"],
            path: "Sources/PlateCLI"
        ),
        .testTarget(
            name: "PlateCoreTests",
            dependencies: ["PlateCore"],
            path: "Tests/PlateCoreTests"
        )
    ]
)
