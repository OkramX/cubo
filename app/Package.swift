// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cubo",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Cubo",
            path: "Sources/Cubo",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageModes: [.v5]
)
