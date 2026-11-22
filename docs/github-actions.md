# GitHub 手动打包与发布

**Release** 是公开的版本说明和安装包下载页。维护者可通过 **Actions** 手动触发构建、冒烟、签名、公证和发布。普通推送和 PR 不运行云端检查或构建。

- [发布 macOS 版本](https://github.com/deernova-studio/linse/actions/workflows/release.yml)：仅正式仓库的 `main` 可以手动触发，支持 M 系列 Mac、macOS 14+。
- [已有 Release](https://github.com/deernova-studio/linse/releases)：已发布版本不会被覆盖。

Mac App Store 使用独立的手动上传工作流，不生成 DMG Release。它需要另外配置商店签名，见 [Mac App Store 说明](app-store.md)；现有 Developer ID 配置无需修改。

## 首次配置发布授权

本机的 `linse-notary` 钥匙串配置不会自动传到 GitHub。云端使用一次性的签名钥匙串，构建结束后清理。

打开仓库 **Settings → Secrets and variables → Actions**，设置以下项目。

### Secrets：3 项

| 名称 | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | 包含 Developer ID Application 证书及对应私钥的 `.p12`，转换为 Base64 后的内容 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出这个 `.p12` 时设置的密码 |
| `APPLE_APP_SPECIFIC_PASSWORD` | Apple 账号的 App 专用密码，用于公证；不是 Apple 登录密码，也不是 Mac 开机密码 |

生成第一项：

1. 在 Mac 的「钥匙串访问 → 登录 → 我的证书」中找到自己的 **Developer ID Application**。展开后应有私钥。
2. 只选中这一个身份，导出为 `.p12`，例如保存到下载目录的 `Linse-Developer-ID.p12`，设置一个导出密码。不要批量导出钥匙串中的其他身份。
3. 在本机终端执行以下命令，将 Base64 内容复制到剪贴板，然后粘贴到 GitHub 对应的 Secret 输入框。

```sh
base64 -i "$HOME/Downloads/Linse-Developer-ID.p12" | pbcopy
```

`.cer` 只有证书，不能代替含私钥的 `.p12`。私钥和密码只填入 GitHub Secrets，不提交到代码或写入聊天；GitHub 保存后不会提供明文查看。

App 专用密码可使用有效的已有密码，也可在 [Apple 账号](https://account.apple.com/) 的「登录与安全 → App 专用密码」中为 GitHub 单独创建。

### Variables：2 项

在同一页面的 **Variables** 标签中填写：

| 名称 | 内容 |
| --- | --- |
| `APPLE_ID` | 开通开发者会员的 Apple 账号邮箱 |
| `APPLE_TEAM_ID` | 证书所属的 10 位 Team ID |

流水线会检查导入的签名身份与 Team ID 一致。GitHub 的上传授权使用任务自带的 `GITHUB_TOKEN`，无需再创建个人访问令牌。

## 每次发布怎么操作

1. 在实际 Mac 上完成需要的功能测试，将本次代码提交并推送到 `main`。
2. 打开 **Actions → 发布 macOS 版本 → Run workflow**，分支选择 **main**。
3. 填写新版本号和新构建号，例如 `0.2.11`、`13`，可选填更新说明。版本号不带 `v`；不要复用已经发布的版本。
4. 点击 **Run workflow**。流程依次校验配置、构建与冒烟、签名应用、公证应用、制作并公证 DMG，最后发布 Release。
5. 成功后到 [Releases](https://github.com/deernova-studio/linse/releases) 下载 `.dmg`。旁边的 `SHA256SUMS.txt` 用于校验完整性。

更新说明填写用户可感知的功能变化或问题修复；发布页自动附上适用系统和安装方法。

流水线自动创建 `v<版本号>` 标签并指向本次运行的固定提交，不需要先手动创建 Release。仅点击 **Run workflow** 时启动发布流程。

发布任务先创建草稿，只有 DMG 和校验文件上传后与 GitHub 返回的 SHA-256 一致，才将草稿发布。同一次运行上传中断时，可使用 **Re-run failed jobs**：继续使用已经打包的产物和同一草稿。已有附件内容不匹配、标签冲突或其他运行留下同名草稿时会停止，需先检查原因，不会直接覆盖文件。构建产物在 Actions 中保留 7 天；成功发布的 Release 附件不受这 7 天限制。

## 发布时的验证范围

手动发布使用 GitHub 托管的 Apple Silicon macOS 15 和 Xcode 26.3，编译 Mac arm64 Release 和 iOS 共享代码。具有 Metal GPU 时运行 3 条真实导入、匹配、导出流程冒烟。无 GPU 时会记录未执行的用例。

仅维护 [8 条关键冒烟用例](smoke.md)，不使用单测框架或测试 target。剩余 5 条人工流程以及 RAW、iPhone / iPad 运行情况需单独验收；共享代码编译不代表设备或模拟器运行通过。

本机也可执行与发布流程相同的检查：

```sh
bash scripts/check-ci.sh
```

发布工作流只有最后上传 Release 的任务具有仓库写权限；签名材料仅注入手动发布的签名步骤。运行发布任务会使用账号的 Actions 配额，普通推送和 PR 不启动任务；本配置不会调整付费额度。

官方说明：[手动运行工作流](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)、[在 macOS runner 安装签名证书](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。
