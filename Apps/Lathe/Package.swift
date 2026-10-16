// swift-tools-version: 6.0
import PackageDescription

// A separate logic-test harness; the application is built by Lathe.xcodeproj.
let package = Package(
    name: "LatheAppChecks",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/LatheKit")],
    targets: [
        .target(
            name: "LatheAppSupport",
            dependencies: [
                .product(name: "LatheDomain", package: "LatheKit"),
                .product(name: "LatheLocalization", package: "LatheKit"),
                .product(name: "LatheProtocol", package: "LatheKit"),
                .product(name: "LatheEngineHost", package: "LatheKit"),
            ],
            path: "Sources",
            exclude: ["LatheApp.swift", "WorkspaceView.swift", "EngineSettingsView.swift"]
        ),
        .testTarget(name: "LatheAppChecks", dependencies: ["LatheAppSupport"], path: "Tests"),
    ]
)
