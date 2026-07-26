// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Claudroom",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudroomCore"),
        // UI lives in a library so both the app and the screenshot renderer can use it.
        .target(name: "ClaudroomUI", dependencies: ["ClaudroomCore"]),
        .executableTarget(name: "ClaudroomApp", dependencies: ["ClaudroomUI"]),
        .executableTarget(name: "ClaudroomShot", dependencies: ["ClaudroomUI"]),
        .testTarget(
            name: "ClaudroomCoreTests",
            dependencies: ["ClaudroomCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ClaudroomUITests",
            dependencies: ["ClaudroomUI"]
        ),
    ]
)
