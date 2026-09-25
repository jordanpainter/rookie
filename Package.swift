// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ChessCoach",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ChessCoach",
            path: "Sources/ChessCoach",
            resources: [.copy("Resources")]
        )
    ]
)
