// swift-tools-version: 6.0
import PackageDescription
import Foundation

let vendorPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/OpenCV/lib").path

let package = Package(
    name: "Lumo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Lumo", targets: ["Lumo"])],
    targets: [
        .target(
            name: "CLineTop",
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("../../Vendor/OpenCV/include")],
            linkerSettings: [
                .unsafeFlags(["-L", vendorPath, "-lopencv_imgproc", "-lopencv_core", "-lz"]),
                .linkedLibrary("c++"), .linkedFramework("Accelerate")
            ]
        ),
        .target(name: "LumoCore", dependencies: ["CLineTop"], resources: [.copy("Resources")]),
        .executableTarget(name: "Lumo", dependencies: ["LumoCore"]),
        .testTarget(name: "LumoCoreTests", dependencies: ["LumoCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
