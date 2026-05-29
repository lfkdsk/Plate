// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Plate",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "PlateCore", targets: ["PlateCore"]),
        .executable(name: "plate-cli", targets: ["PlateCLI"])
    ],
    targets: [
        .target(
            name: "PlateCore",
            path: "Sources/PlateCore",
            resources: [
                // The web gallery's HTML lives as a real file, loaded at runtime
                // via Bundle.module (see WebFrontend) rather than a string literal.
                .copy("Web/Resources/gallery.html"),
            ],
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
