# 临色 · Linse

原生照片调色 App：导入原图与目标风格，匹配颜色，并继续调整、添加蒙版和导出。

本仓库是唯一维护的产品工程，面向 **macOS 14+** 和 **iPhone / iPad（iOS 17+）**。两端共用 Swift / SwiftUI 与 Metal 实现；旧 TypeScript / Electron App 已退役。

## 工程结构

| 目录 | 职责 |
| --- | --- |
| `Sources/LinseCore` | 调色渲染、匹配、蒙版、资源与导出 |
| `Sources/LinseUI` | 共享界面与编辑状态，以及两端的界面适配 |
| `Sources/LinseMac` | macOS App 入口 |
| `iOS/Linse.xcodeproj` | iPhone / iPad App 工程，引用本地 Swift 包 |
| `Tests` | 核心与编辑流程的回归测试 |

## macOS 开发与运行

用 Xcode 打开 `Package.swift`，选择 `LinseMac` → `My Mac`，运行即可。也可以在仓库目录执行：

```sh
swift run LinseMac
```

构建可直接打开的本机 App：

```sh
bash scripts/package.sh
```

产物为 `build/临色.app`，脚本使用本机临时签名，供本地测试。

## 移动端开发与运行

用 Xcode 打开 `iOS/Linse.xcodeproj`，选择 `Linse` 目标，以及 iPhone / iPad 模拟器或真机。运行模拟器需要安装对应运行环境；真机需要配置签名。

仅检查共享代码能否面向 iOS 编译，不需要启动模拟器：

```sh
bash scripts/check-ios.sh
```

这项检查不等同于完整 iOS App 的运行验证。

## 验证与维护

```sh
swift test
swift build -c release --product LinseMac
```

修改 `Sources/LinseCore/Shaders.metal` 后，先运行 `python3 scripts/embed-shader.py` 更新内嵌源码，再进行相关验证。

构建和测试不依赖 Node.js、Electron 或其他工程目录。`Tests/LinseCoreTests/Fixtures/Electron` 仅保留旧版生成的固定颜色参考数据，用来检测原生渲染回归；来源与容差见[参考数据说明](Tests/LinseCoreTests/Fixtures/README.md)。
