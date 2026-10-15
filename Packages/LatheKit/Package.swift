// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatheKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LatheDomain", targets: ["LatheDomain"]),
        .library(name: "LatheProtocol", targets: ["LatheProtocol"]),
        .library(name: "LatheExecution", targets: ["LatheExecution"]),
        .library(name: "LatheProviders", targets: ["LatheProviders"]),
        .library(name: "LatheTools", targets: ["LatheTools"]),
        .library(name: "LatheEngineHost", targets: ["LatheEngineHost"]),
        .executable(name: "lathe-runner", targets: ["LatheRunner"]),
        .executable(name: "lathe-engine", targets: ["LatheEngine"]),
        .executable(name: "lathe", targets: ["LatheCLI"]),
    ],
    targets: [
        .target(name: "LatheDomain"),
        .target(name: "LatheProtocol", dependencies: ["LatheDomain"]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "CLatheExecution", publicHeadersPath: "include"),
        .target(name: "LatheExecution", dependencies: ["CLatheExecution"]),
        .target(name: "LatheProviders", dependencies: ["LatheDomain"]),
        .target(name: "LatheTools", dependencies: ["LatheDomain", "LatheExecution"]),
        .executableTarget(name: "LatheRunner", dependencies: ["LatheExecution"]),
        .target(name: "LathePersistence", dependencies: ["LatheDomain", "CSQLite"]),
        .target(name: "LatheRuntime", dependencies: ["LatheDomain", "LathePersistence", "LatheProviders", "LatheTools"]),
        .target(name: "LatheEngineHost", dependencies: ["LatheDomain", "LatheProtocol", "LatheRuntime", "LatheProviders"]),
        .executableTarget(name: "LatheEngine", dependencies: ["LatheDomain", "LatheProtocol", "LatheEngineHost"]),
        .executableTarget(name: "LatheCLI", dependencies: ["LatheDomain", "LatheProtocol"]),
        .testTarget(name: "LatheKitTests", dependencies: ["LatheDomain", "LatheProtocol", "LatheRuntime", "LathePersistence", "LatheExecution", "LatheProviders", "LatheTools", "LatheEngineHost"]),
    ]
)
