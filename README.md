# 临色 · Linse

原生照片调色 App：导入原图与目标风格，匹配颜色，并继续调整、添加蒙版和导出。

本仓库是唯一维护的产品工程，面向 **Apple 芯片（M 系列）的 Mac，macOS 14+** 和 **iPhone / iPad（iOS 17+）**。两端共用 Swift / SwiftUI 与 Metal 实现；旧 TypeScript / Electron App 已退役。

## 图片与 RAW 导入

普通图片通过系统图像解码导入；相机 RAW 使用专门的 RAW 解码流程，保留完整尺寸与高精度编辑输入。RAW 解码失败时不会静默使用内嵌小预览，会说明原因并保留已有照片和编辑。iPhone / iPad 可以从相册或“文件”选择图片；需要确定使用 RAW 原始文件时，选择“从文件选择（含 RAW）”。

实际兼容范围取决于设备系统支持的相机型号和压缩方式，不能将支持某种扩展名等同于所有机型都兼容。独立回归样片覆盖 DNG / Apple ProRAW、CR2、CR3、NEF、ARW、RAF、ORF、RW2；来源、下载校验与测试方式见 [RAW 测试矩阵](Tests/LinseCoreTests/Fixtures/RAW/README.md)。目前未提供 RAW 专用显影参数面板。

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

`bash scripts/package.sh --dev` 会生成独立的 `build/dev/临色.app`。更新之前关闭对应的开发版窗口，保留其他版本中的编辑；无需生成安装包。

Mac 版的 AI 接口设置与 API Key 一起明文保存到 `~/.linse/config.json`，不再使用钥匙串。首次升级时会保留旧版接口设置，需要在 AI 设置里重新填入一次 API Key；保存后，后续启动与更新都会读取这个配置文件。旧钥匙串条目不会自动读取或删除。iPhone / iPad 的存储方式本次不变。

## macOS 正式签名与分发

本机安装有效的 **Developer ID Application** 证书及对应私钥后，构建仅适用于 Apple 芯片（M 系列）的 arm64 应用：

```sh
bash scripts/package.sh --release
```

如果存在多个开发者签名身份，用 `SIGNING_IDENTITY` 指定完整的 `Developer ID Application: ...` 名称。脚本启用强化运行时和安全时间戳，在 `build/release-candidates` 下生成候选应用及已签名 ZIP；此时尚未公证，不是最终对外分发包。

首次公证需将账号授权保存到系统钥匙串。使用 Apple 账号的 App 专用密码，在命令提示时输入，不要写进脚本或提交到仓库：

```sh
xcrun notarytool store-credentials linse-notary \
  --apple-id '<Apple 账号>' --team-id '<Team ID>'
```

再对候选应用执行公证和 DMG 制作（路径中的版本与构建号以实际产物为准）：

```sh
NOTARY_PROFILE=linse-notary bash scripts/notarize.sh \
  'build/release-candidates/Linse-0.2.10-build12/临色.app'
```

脚本先公证应用并附上票据，再生成带“应用程序”快捷入口的 DMG，对 DMG 签名、公证并验证。成功后 `build/releases` 中的 DMG 才是可对外分发的版本，同时生成 SHA-256 校验文件。日志与提交 ID 保存在候选应用旁的 `notarization` 目录，中断后可重新运行继续等待原申请。应用内容改变后应更新版本号重新构建。

指定新版本与构建号时，在打包命令前设置 `LINSE_VERSION` 和 `LINSE_BUILD_NUMBER`，例如：

```sh
LINSE_VERSION=0.2.11 LINSE_BUILD_NUMBER=13 bash scripts/package.sh --release
```

## GitHub 自动检查与发布

推送到 `main` 或提交 PR 后，GitHub Actions 自动运行测试、Mac arm64 编译和 iOS 共享代码编译。正式发布在 [Actions → 发布 macOS 版本](https://github.com/ruixingshi/linse/actions/workflows/release.yml) 手动触发：填写新版本号和构建号，完成签名、公证与 DMG 校验后发布到私有仓库的 Release。

首次云端发布需要配置签名证书及公证授权，具体步骤、检查范围和失败恢复见 [GitHub Actions 使用说明](docs/github-actions.md)。

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
