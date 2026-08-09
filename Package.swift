// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentSignalBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AgentSignalBar", targets: ["AgentSignalBar"])
    ],
    targets: [
        .executableTarget(
            name: "AgentSignalBar",
            path: "Sources/AgentSignalBar"
        )
    ]
)
