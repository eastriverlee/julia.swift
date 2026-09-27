// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "julia.swift",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "JuliaSwift", type: .static, targets: ["JuliaSwift"]),
        .executable(name: "julia", targets: ["JuliaCLI"]),
        .executable(name: "julia-benchmark", targets: ["JuliaBenchmark"]),
    ],
    targets: [
        .target(
            name: "CJuliaRuntime",
            cSettings: [.headerSearchPath("private")],
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
        ),
        .target(name: "JuliaSwift", dependencies: ["CJuliaRuntime"]),
        .executableTarget(name: "JuliaCLI", dependencies: ["JuliaSwift"]),
        .executableTarget(name: "JuliaBenchmark", dependencies: ["JuliaSwift"]),
        .testTarget(name: "JuliaSwiftTests", dependencies: ["JuliaSwift"]),
    ]
)
