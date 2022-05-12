// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TorrentKit",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "TorrentKit",
            targets: ["TorrentKit"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/Samasaur1/BencodingKit", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/Kitura/BlueSocket", .upToNextMajor(from: "2.0.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "TorrentKit",
            dependencies: ["BencodingKit", .product(name: "Socket", package: "BlueSocket")]),
        .testTarget(
            name: "TorrentKitTests",
            dependencies: ["TorrentKit"]),
    ]
)
