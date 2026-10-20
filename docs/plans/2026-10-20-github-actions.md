# GitHub Actions Implementation Plan

**后续调整（2026-10-20）：** 用户明确只需要手动打包发布，已移除独立 CI 工作流。普通 push 和 PR 不运行检查，验证保留在手动发布流程中。以下为最初实施记录，当前操作以 `docs/github-actions.md` 为准。

**Goal:** 用户选择自动检查代码、从 GitHub 手动触发 macOS 打包、签名、公证和私有 Release 发布。

**Architecture:** 代码检查与签名发布分开；使用 GitHub 托管的 Apple Silicon macOS 15、Xcode 16.4。发布只接受 main 的固定提交、合法版本和构建号；编译签名任务只有读取代码权限，完成公证的产物交给独立发布任务上传。已有 v0.2.10 保留。

**Tech Stack:** GitHub Actions、Swift Package Manager、Python 标准库、Developer ID、notarytool、GitHub REST API。

## Task 1: 自动检查

- 新增 `.github/workflows/ci.yml`，main 推送、PR 和手动触发；设定并发取消与超时。
- 新增 `scripts/check-ci.sh`，验证脚本、Mac Release 编译、Swift 测试及 iOS 共享代码编译。
- 检测 Metal 设备；没有 GPU 的虚拟机仅运行独立于 GPU 的测试，并在结果摘要中明确范围。完整 GPU/RAW 回归仍需实际 Mac。

## Task 2: 云端签名与公证

- `scripts/package.sh` 接受经过严格验证的版本、构建号环境变量；默认本地版本保持不变。
- `scripts/notarize.sh` 支持显式临时钥匙串路径，保持本地配置兼容。
- 新增临时签名钥匙串初始化脚本；仅允许 GitHub 托管 Mac 执行，按需导入单个 Developer ID 身份，完成后清理。
- 新增 `.github/workflows/release.yml`，手动输入版本与构建号，先检查私有仓库、标签冲突与授权，再编译、公证；未配置 Secrets 时明确失败。

## Task 3: 私有发布与验证

- 新增 GitHub 发布辅助脚本；创建草稿、上传 DMG/校验文件、核对远端 SHA-256，再发布；固定目标提交，保留同一次运行的草稿以便恢复。
- 单元测试验证非法版本/路径、校验失败和草稿恢复，不访问真实 GitHub。
- 添加使用文档和签名授权配置说明。签名私钥、公证密码不写入代码或日志。
- 检查 workflow 语法、本地脚本、云端 CI 实际结果；提交并同步配置。云端发布授权补齐后再验证完整 CD，不覆盖已发布版本。
