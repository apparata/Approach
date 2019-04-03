// swift-tools-version:5.0

import PackageDescription

let package = Package(
    name: "Approach",
    platforms: [
        .macOS(.v10_14), .iOS(.v12), .tvOS(.v12)
    ],
    products: [
        .library(name: "Approach", targets: ["Approach"]),
    ],
    targets: [
        .target(name: "Approach", dependencies: []),
    ]
)
