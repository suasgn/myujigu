// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Myujigu",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Myujigu", targets: ["Myujigu"]),
    ],
    targets: [
        .target(
            name: "MyujiguCore"
        ),
        .executableTarget(
            name: "Myujigu",
            dependencies: ["MyujiguCore"]
        ),
        .testTarget(
            name: "MyujiguCoreTests",
            dependencies: ["MyujiguCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
