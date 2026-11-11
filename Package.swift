// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "PhotoAtelier",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PhotoCore", targets: ["PhotoCore"]),
        .executable(name: "PhotoAtelier", targets: ["PhotoAtelier"])
    ],
    targets: [
        .target(name: "CLensfunBridge", publicHeadersPath: "include",
                cSettings: [.headerSearchPath("../../.dependencies/lensfun/include")]),
        .target(name: "PhotoCore", dependencies: ["CLensfunBridge"]),
        .executableTarget(name: "PhotoAtelier", dependencies: ["PhotoCore"]),
        .testTarget(name: "PhotoCoreTests", dependencies: ["PhotoCore"])
    ]
)
