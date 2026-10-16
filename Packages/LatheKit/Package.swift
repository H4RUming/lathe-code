// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatheKit",
    defaultLocalization: "ko",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LatheDomain", targets: ["LatheDomain"]),
        .library(name: "LatheLocalization", targets: ["LatheLocalization"]),
        .library(name: "LatheProtocol", targets: ["LatheProtocol"]),
        .library(name: "LatheExecution", targets: ["LatheExecution"]),
        .library(name: "LatheProviders", targets: ["LatheProviders"]),
        .library(name: "LatheTools", targets: ["LatheTools"]),
        .library(name: "LatheEngineHost", targets: ["LatheEngineHost"]),
        .executable(name: "lathe-runner", targets: ["LatheRunner"]),
        .executable(name: "lathe-engine", targets: ["LatheEngine"]),
        .executable(name: "lathe", targets: ["LatheCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.2"),
    ],
    targets: [
        .target(name: "LatheDomain", dependencies: ["LatheLocalization"]),
        .target(name: "LatheLocalization", resources: [.process("Resources")]),
        .target(name: "LatheProtocol", dependencies: ["LatheDomain", "LatheLocalization"]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "CLatheExecution", publicHeadersPath: "include"),
        .target(name: "LatheExecution", dependencies: ["CLatheExecution", "LatheLocalization"]),
        .target(name: "LatheProviders", dependencies: ["LatheDomain", "LatheLocalization"]),
        .target(name: "LatheTools", dependencies: ["LatheDomain", "LatheExecution", "LatheLocalization", "SwiftSoup"]),
        .executableTarget(name: "LatheRunner", dependencies: ["LatheExecution", "LatheLocalization"]),
        .target(name: "LathePersistence", dependencies: ["LatheDomain", "CSQLite", "LatheLocalization"]),
        .target(name: "LatheRuntime", dependencies: ["LatheDomain", "LathePersistence", "LatheProviders", "LatheTools", "LatheLocalization"]),
        .target(name: "LatheEngineHost", dependencies: ["LatheDomain", "LatheProtocol", "LatheRuntime", "LatheProviders", "LatheLocalization"]),
        .executableTarget(name: "LatheEngine", dependencies: ["LatheDomain", "LatheProtocol", "LatheEngineHost", "LatheLocalization"]),
        .executableTarget(name: "LatheCLI", dependencies: ["LatheDomain", "LatheProtocol", "LatheLocalization"]),
        .testTarget(name: "LatheKitTests", dependencies: ["LatheDomain", "LatheProtocol", "LatheRuntime", "LathePersistence", "LatheExecution", "LatheProviders", "LatheTools", "LatheEngineHost", "LatheLocalization"]),
    ]
)
