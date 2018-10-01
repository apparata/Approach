// swift-tools-version:4.2
// Deployment target: iOS 12, macOS 10.14 Mojave, tvOS 12
// Build with specified deployment target:
// swift build -Xswiftc "-target" -Xswiftc "x86_64-apple-macosx10.14"

import PackageDescription

let package = Package(
    name: "Approach",
    products: [
        .library(name: "Approach", targets: ["Approach"]),
    ],
    targets: [
        .target(name: "Approach", dependencies: []),
    ]
)
