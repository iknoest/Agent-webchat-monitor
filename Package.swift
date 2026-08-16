// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentSignalBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AgentSignalBar", targets: ["AgentSignalBar"]),
        .library(name: "AgentSignalBarCore", targets: ["AgentSignalBarCore"]),
        .executable(name: "Stage1TestRunner", targets: ["Stage1TestRunner"])
    ],
    targets: [
        .target(
            name: "AgentSignalBarCore",
            path: "Sources/AgentSignalBar"
        ),
        .executableTarget(
            name: "AgentSignalBar",
            dependencies: ["AgentSignalBarCore"],
            path: "Sources/AgentSignalBarApp"
        ),
        .executableTarget(
            name: "Stage1TestRunner",
            dependencies: ["AgentSignalBarCore"],
            path: "Sources/Stage1TestRunner"
        ),
        .testTarget(
            name: "AgentSignalBarTests",
            dependencies: ["AgentSignalBarCore"],
            path: "Tests/AgentSignalBarTests"
        )
    ]
)
