// swift-tools-version: 5.10
// 临色（Swift 版）：核心调色与匹配算法放在 LinseCore，Mac / iOS 应用共用。
import PackageDescription

let package = Package(
    name: "Linse",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LinseCore", targets: ["LinseCore"]),
        .executable(name: "LinseMac", targets: ["LinseMac"]),
    ],
    targets: [
        .target(name: "LinseCore", exclude: ["Shaders.metal"]),
        .executableTarget(name: "LinseMac", dependencies: ["LinseCore"]),
        .testTarget(name: "LinseCoreTests", dependencies: ["LinseCore"]),
    ]
)
