// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "Approach",
    platforms: [
        .macOS(.v13), .iOS(.v16), .tvOS(.v16), .visionOS(.v1)
    ],
    products: [
        .library(name: "Approach", targets: ["Approach"]),
    ],
    targets: [
        .target(name: "Approach", dependencies: []),
    ]
)
