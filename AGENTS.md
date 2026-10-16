# Linse maintenance scope

- Maintain the native Swift project for macOS and iPhone / iPad. The TypeScript / Electron app was retired on 2026-10-16; do not recreate or depend on that app unless the user explicitly changes this direction.
- Keep shared rendering and editing logic in `LinseCore` and `LinseUI`. Platform entry points are `Sources/LinseMac` and `iOS/Linse.xcodeproj`.
- Preserve the existing deployment targets unless the user requests a change. See `README.md` for build and run entry points.
- The checked-in `Fixtures/Electron` data is a historical, independent regression baseline, not an active app dependency. Preserve its provenance and do not regenerate expected output from the renderer under test just to make tests pass.
- Select validation appropriate to the change: `swift test`, the macOS build, and `scripts/check-ios.sh`. The iOS script checks shared-code compilation only; report actual device/simulator coverage separately.
