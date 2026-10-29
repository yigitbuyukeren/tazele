// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tazele",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Tazele", targets: ["Tazele"])],
    targets: [
        .target(name: "TazeleCore"),
        .executableTarget(name: "Tazele", dependencies: ["TazeleCore"]),
        .testTarget(name: "TazeleCoreTests", dependencies: ["TazeleCore"]),
    ]
)
