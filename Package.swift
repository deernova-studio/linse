// swift-tools-version: 5.10
// 临色（Swift 版）：核心调色与匹配算法放在 LinseCore，界面和编辑状态放在 LinseUI，Mac / iOS 应用共用；
// LinseMac 是 Mac 应用入口，iOS 应用入口在 iOS/ 下的 Xcode 工程里。
import PackageDescription

let package = Package(
    name: "Linse",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LinseCore", targets: ["LinseCore"]),
        .library(name: "LinseUI", targets: ["LinseUI"]),
        .executable(name: "LinseMac", targets: ["LinseMac"]),
    ],
    targets: [
        .target(name: "LinseCore", exclude: ["Shaders.metal"]),
        .target(name: "LinseUI", dependencies: ["LinseCore"]),
        .executableTarget(name: "LinseMac", dependencies: ["LinseUI"]),
        .testTarget(name: "LinseCoreTests", dependencies: ["LinseCore"]),
    ]
)
