// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatheKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LatheDomain", targets: ["LatheDomain"]),
        .library(name: "LatheProtocol", targets: ["LatheProtocol"]),
        .executable(name: "lathe-engine", targets: ["LatheEngine"]),
        .executable(name: "lathe", targets: ["LatheCLI"]),
    ],
    targets: [
        .target(name: "LatheDomain"),
        .target(name: "LatheProtocol", dependencies: ["LatheDomain"]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "LathePersistence", dependencies: ["LatheDomain", "CSQLite"]),
        .target(name: "LatheRuntime", dependencies: ["LatheDomain", "LathePersistence"]),
        .executableTarget(name: "LatheEngine", dependencies: ["LatheDomain", "LatheProtocol", "LatheRuntime"]),
        .executableTarget(name: "LatheCLI", dependencies: ["LatheDomain", "LatheProtocol"]),
        .testTarget(name: "LatheKitTests", dependencies: ["LatheDomain", "LatheProtocol", "LatheRuntime", "LathePersistence"]),
    ]
)
