// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cubo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Cubo",
            path: "Sources/Cubo",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
