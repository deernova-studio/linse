# Mac App Store

首次发布采用免费下载、无内购。仅支持 Apple 芯片 Mac，最低 macOS 14。现有 Developer ID DMG 发布方式保留。

## 应用记录

- 名称：临色
- Bundle ID：`app.linse.mac`
- Apple ID：`6824873396`
- Team ID：`LVWWAF3DBK`
- SKU：`linse-mac`
- 首个商店版本：`0.3.0`，构建 `14`
- 定价基准：中国大陆（CNY），免费
- 销售范围：仅中国大陆
- [App Store Connect](https://appstoreconnect.apple.com/apps/6824873396/distribution/macos/version/inflight)

## 当前提交状态

2026 年 10 月 22 日 17:02（中国时间），`0.3.0 (14)` 已提交 Apple，后台确认状态为 **等待审核**。审核通过后手动发布，尚未上架。

- [本次审核记录](https://appstoreconnect.apple.com/apps/6824873396/distribution/reviewsubmissions/details/460022bf-e0fc-4ba8-afb0-6671d6b104e7)
- 提交 ID：`460022bf-e0fc-4ba8-afb0-6671d6b104e7`
- 已保存免费定价、中国大陆供应范围、4+ 年龄分级、内容版权、描述、关键词、支持 URL 和隐私政策 URL。
- 已上传三张实际商店版截图，见 [截图说明](store-screenshots.md)。
- 已保存审核联系人和测试说明；应用不要求登录。联系电话只保留在 Apple 后台，不记录在仓库。
- 经负责人确认，已发布 App Privacy：照片或视频仅用于 App 功能、可能与用户的 AI 服务账号关联，不用于追踪。应用没有自己的账号系统、广告或行为统计；本地调色不上传照片。

审核专用 AI 凭证尚未提供；审核说明已明确 AI 是用户自备 API Key 的可选功能，并提供联系开发者协助测试的方式。若审核团队要求访问资料，应通过审核后台处理，不提交个人生产 API Key 到仓库。

商店版使用 `macOS/Linse.xcodeproj`，引用现有共享 Swift 包。AI 配置保存在应用沙盒的 `Application Support/Linse/config.json`，仍是本地 JSON；不会读取沙盒外的 `~/.linse/config.json`。DMG 版继续使用原来的配置位置。

## 公开支持与隐私政策

- 技术支持 URL：https://ruixingshi.github.io/linse-support/
- 隐私政策 URL：https://ruixingshi.github.io/linse-support/privacy.html
- 公开支持邮箱：`2946193417@qq.com`
- 网页仓库：[ruixingshi/linse-support](https://github.com/ruixingshi/linse-support)，仅包含两个 HTML 页面和 `.nojekyll`；应用源码仓库继续保持私有。

2026 年 10 月 22 日经负责人确认后发布，已验证两个 HTTPS 页面无需登录即可访问。网页源文件保留在 `store-site`，更新后需同步至网页仓库的 `main` 分支。

## 本机构建

```sh
# 不需要开发者证书的沙盒测试版本
bash scripts/app-store.sh build

# 需要在 Xcode → Settings → Accounts 登录开发者账号
bash scripts/app-store.sh archive
bash scripts/app-store.sh export
```

产物位于 `build/app-store/Linse-0.3.0-build14`。用 `LINSE_VERSION` 和 `LINSE_BUILD_NUMBER` 指定其他版本；已存在的归档不会被覆盖。

商店分发需要 Apple Distribution（或 Mac App Distribution）应用证书、Mac Installer Distribution 安装包证书，以及对应的 Mac App Store 描述文件。Developer ID 证书用于商店外分发，不能代替这些证书。

本机 Xcode 自动签名可以使用 Apple 云端管理的分发证书；云端管理证书的私钥不能从本机导出。GitHub 流程使用下文单独配置的、可导出的分发证书。

## GitHub 手动上传

工作流 `.github/workflows/app-store.yml` 仅由 **Run workflow** 手动启动，普通 push 和 PR 不触发。

在仓库 Actions 设置中增加：

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Secret | `APP_STORE_CERTIFICATE_P12_BASE64` | 同一个 `.p12` 中的商店应用证书、安装包证书及各自私钥，转为 Base64 |
| Secret | `APP_STORE_CERTIFICATE_PASSWORD` | 该 `.p12` 的导出密码 |
| Secret | `APP_STORE_PROFILE_BASE64` | `app.linse.mac` 的 Mac App Store 分发描述文件，转为 Base64 |
| Variable | `APP_STORE_APP_ID` | `6824873396` |

复用现有 `APPLE_APP_SPECIFIC_PASSWORD` Secret 和 `APPLE_ID`、`APPLE_TEAM_ID` Variables。不修改 DMG 发布使用的 Secrets。私钥、密码和描述文件不得提交到仓库。

手动运行 **上传 Mac App Store 版本**，填写与 Apple 后台一致的版本号及新的构建号。流程检查共享代码，归档、签名并导出 PKG，验证后上传 Apple 后台。签名资料只在临时钥匙串中使用，结束时清理；PKG 在 Actions 中保留 7 天。

上传成功后还要等待 Apple 处理，在 App Store Connect 选择构建、补齐资料并提交审核。该工作流不会提交审核或自动上架。版本发布方式使用“手动发布”。

## 后续版本提交检查

- 免费定价、销售地区、年龄分级与版权信息。
- 在 Apple 后台填写上文已发布的技术支持和隐私政策 URL。
- 实际商店版的截图、描述，以及审核联系人的电话和邮箱。
- 核对 App Privacy 声明：本地编辑不上传照片；用户同意后，可选 AI 功能将缩小预览发送给用户配置的服务。服务可能将照片与其 API 账号关联；不能直接声明“完全不收集数据”。
- 如需审核 AI 功能，提供可供审核使用的服务和凭证，或先与审核团队明确测试方式；不得把个人生产 API Key 放进代码、截图或公开资料。
- 实测沙盒环境中的导入、离线匹配、导出、设置保存和 AI 发送授权。

商店文案和审核步骤见 [商店资料](store-listing.md)。上传构建、提交审核、审核通过和正式上架是不同状态，应分别确认。
