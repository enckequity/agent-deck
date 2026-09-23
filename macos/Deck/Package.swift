// swift-tools-version:5.10
import PackageDescription

// Deck — a native macOS front end for agent-deck. It only drives the
// `agent-deck` CLI and ~/bin/deck-task, so upstream agent-deck releases
// never conflict with it.
let package = Package(
    name: "Deck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Deck", path: "Sources/Deck"),
        .testTarget(name: "DeckTests", dependencies: ["Deck"], path: "Tests/DeckTests",
                    resources: [.copy("Fixtures")])
    ]
)
