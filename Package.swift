// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lumo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Lumo", targets: ["Lumo"])],
    targets: [
        .target(name: "LumoCore", resources: [.copy("Resources")]),
        .executableTarget(name: "Lumo", dependencies: ["LumoCore"]),
        .testTarget(name: "LumoCoreTests", dependencies: ["LumoCore"])
    ],
    swiftLanguageModes: [.v5]
)
