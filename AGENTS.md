# Deernova Studio 仓库偏好

用户明确要求（2026-11-08）：对 Git remote 所属组织为 `deernova-studio` 的仓库，未来不新增或维护单元测试，不引入单测框架、测试 target 或覆盖率门禁；每个仓库只保留 5–10 条关键冒烟用例，不能将单测简单改名为冒烟。修改时运行必要构建和相关冒烟并报告未验收项。此约定不适用于其他组织仓库，不自动授权批量修改未被请求处理的仓库。

---

# Linse maintenance scope

- Maintain the native Swift project for macOS and iPhone / iPad. The TypeScript / Electron app was retired on 2026-10-16; do not recreate or depend on that app unless the user explicitly changes this direction.
- macOS supports Apple Silicon (M-series, arm64) only. Do not add Intel or universal Mac distribution builds unless the user changes this direction.
- Keep shared rendering and editing logic in `LinseCore` and `LinseUI`. Platform entry points are `Sources/LinseMac` and `iOS/Linse.xcodeproj`; `macOS/Linse.xcodeproj` reuses the Mac entry point for sandboxed App Store builds.
- Preserve the existing deployment targets unless the user requests a change. See `README.md` for build and run entry points.
- Use GitHub Actions only for manually triggered releases. Keep validation in the release workflow; do not add automatic push or pull-request checks unless the user requests them.
- The checked-in `Fixtures/Electron` data is a historical, independent regression baseline, not an active app dependency. Preserve its provenance and do not regenerate expected output from the renderer under test just to make tests pass.
- Do not add or maintain unit tests, test frameworks, test targets, or coverage gates. Keep only the eight product-flow smoke cases in `docs/smoke.md`; do not relabel unit tests as smoke cases.
- Select validation appropriate to the change: `bash scripts/check-ci.sh` (Mac arm64 build, iOS shared-code compilation, and available automated smoke flows). Report skipped smoke cases and actual device/simulator coverage separately; shared-code compilation is not runtime acceptance.
