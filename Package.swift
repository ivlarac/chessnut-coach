// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChessnutCoachGameCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "ChessnutCoachGameCore", targets: ["ChessnutCoachGameCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/chesskit-app/chesskit-swift.git", branch: "master")
    ],
    targets: [
        .target(
            name: "ChessnutCoachGameCore",
            dependencies: [
                .product(name: "ChessKit", package: "chesskit-swift")
            ],
            path: "ChessnutCoach",
            exclude: [
                "BoardController.swift",
                "ChessnutCoachApp.swift",
                "ContentView.swift"
            ],
            sources: [
                "GameModels.swift",
                "OTBGameSession.swift"
            ]
        ),
        .testTarget(
            name: "ChessnutCoachGameCoreTests",
            dependencies: [
                "ChessnutCoachGameCore",
                .product(name: "ChessKit", package: "chesskit-swift")
            ],
            path: "ChessnutCoachTests"
        )
    ]
)
