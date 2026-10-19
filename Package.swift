// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacUtility",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacUtility", path: "Sources/MacUtility", resources: [.copy("Memes")]),
        .executableTarget(name: "macutility-fan", path: "Sources/macutility-fan"),
    ]
)

