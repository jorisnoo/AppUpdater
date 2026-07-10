// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [.macOS(.v12)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "AppUpdater",
            targets: ["AppUpdater"]),
        .library(
            name: "AppUpdaterMocks",
            targets: ["AppUpdaterMocks"]),
        .executable(name: "AppUpdaterMockRunner", targets: ["AppUpdaterMockRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/Version.git", .upToNextMajor(from: "2.0.1"))
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AppUpdater",
            dependencies: [
                "Version"
            ]
        ),
        .target(
            name: "AppUpdaterMocks",
            dependencies: ["AppUpdater"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AppUpdaterMockRunner",
            dependencies: ["AppUpdater", "AppUpdaterMocks"]
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: ["AppUpdater", "AppUpdaterMocks"]
        )
    ]
)
