// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PodFill",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that isn't UI: URL handling, spotdl command line, output parser, process runner.
        .target(name: "PodFillCore"),
        // The SwiftUI app.
        .executableTarget(name: "PodFill", dependencies: ["PodFillCore"]),
        // `swift test` can't work on Command Line Tools only (no XCTest, no Swift Testing macro plugin),
        // so the parser tests are a small executable: `swift run PodFillSelfCheck`.
        .executableTarget(name: "PodFillSelfCheck", dependencies: ["PodFillCore"]),
    ]
)
