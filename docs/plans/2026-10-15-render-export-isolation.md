# GPU and Export Isolation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Protect queued GPU draws from lookup-table overwrites and make image/LUT exports own consistent resources; review, verify, and commit the finished changes.

**Architecture:** Keep the shared Metal pipeline. Curve/HSL textures become immutable snapshots cached by their parameter values. A dedicated export actor owns its renderer and serializes complete image/LUT operations, using captured value snapshots of LUT and smart-mask assets. AppState coordinates presentation without exposing the export renderer.

**Tech Stack:** Swift 5.10 package, SwiftUI, Metal, Core Image, XCTest; macOS 14 / iOS 17.

## Design decisions

- Choose immutable lookup textures over blocking the UI until GPU completion. Each changed table is only a few KB, and unchanged parameters reuse the latest texture. Metal command buffers retain bound textures through execution. A completion-driven texture pool can be considered only if profiling warrants the complexity.
- Choose a private export actor over per-view busy checks alone. Actor operations contain no suspension points while using the renderer. Both entry points also respect the existing UI busy state.
- Capture external LUT/mask values at job creation, so deleting an asset or changing the current document cannot alter later tiles in an export.
- Keep each iOS export in its own temporary directory. A file owner stays alive through sharing or the Photos completion callback and removes the directory when released.
- Keep existing public AppState initialization behavior; add an internal dependency-based initializer for tests that does not read user settings or credentials.
- User authorized implementation, review, corrections, and a final Git commit. Proceed through all steps without a separate approval checkpoint. Keep the existing clean checkout; commit the plan together with the verified implementation.

## Task 1: Add failing regression coverage

**Files:** `Package.swift`, `Tests/LinseCoreTests/RenderIsolationTests.swift`, `Tests/LinseUITests/ExportTests.swift`, `Sources/LinseUI/AppState.swift` (test initialization seam only).

1. Add deterministic GPU tests that hold command execution behind a shared event, encode differing curve/HSL settings, then compare each result to serial reference renders. Include multiple draws in a single command buffer.
2. Add a LinseUI test target with temporary LUT storage. Verify LUT export is refused while busy and export output is unaffected by deleting a captured LUT.
3. Run `swift test --filter RenderIsolationTests` and `swift test --filter ExportTests`; record failures against the original implementation. No sleeps or user photos/credentials are required to provoke resource overwrite.

## Task 2: Fix lookup-texture lifetime

**Files:** `Sources/LinseCore/Renderer.swift`, `Tests/LinseCoreTests/RenderIsolationTests.swift`.

1. Replace mutable shared curve/HSL texture writes with fully initialized immutable textures keyed by parameter snapshots.
2. Prepare resources before creating a render encoder, propagate allocation errors, and document serialized CPU ownership plus retained-resource command-buffer expectations.
3. Run the frame-isolation tests and existing identity test. Check that unchanged lookups reuse textures and later changes cannot change queued output.

## Task 3: Isolate and serialize exports

**Files:** `Sources/LinseCore/ExportService.swift`, `Sources/LinseUI/AppState.swift`, `Sources/LinseUI/MacRoot.swift`, `Sources/LinseUI/IOSRoot.swift`, `Sources/LinseUI/TemporaryExportFile.swift`, `Tests/LinseCoreTests/ExportServiceTests.swift`, `Tests/LinseUITests/ExportTests.swift`, `Tests/LinseUITests/TemporaryExportFileTests.swift`.

1. Capture the referenced LUT and required mask bitmaps into immutable export assets.
2. Move image rendering/writing and LUT baking into a private-renderer actor; release per-job images/providers on success and failure.
3. Route macOS and iOS LUT export through the asynchronous shared AppState entry point; keep progress and busy state consistent and prevent queued progress from reviving completed operations.
4. Test concurrent service requests, captured asset consistency, busy rejection, recovery after a failed output write, and successful completion of the actual UI-layer export entry points.

## Task 4: Review, correct, and verify

1. Review the complete diff independently of the implementation sequence: queued GPU resource ownership, actor suspension, data snapshots, temporary-file isolation, UI error handling, and both platform call sites.
2. Fix findings and extend relevant tests before rerunning them.
3. Run `swift test`, `swift build -c release --product LinseMac`, and `bash scripts/check-ios.sh`. Use Metal validation for the new rendering tests. The previous full Xcode iOS build was blocked by the locally missing iOS 18.5 platform; do not equate shared-target compilation with simulator/device testing.
4. Run `git diff --check`, verify that no credentials or generated build files are staged, update this document with evidence, and commit all completed changes.

## Evidence and completion

- Regression tests ran against the original implementation before the fixes: all three queued-GPU tests failed (maximum pixel differences 114, 98, and 138), and the busy LUT-export test failed because the request was accepted. The GPU tests use an explicit shared-event gate, including multiple draws in one command buffer.
- The fixes pass synthetic-pixel comparisons for overlapping draws, concurrent image/LUT requests, 16-bit TIFF output, and multi-tile export after deleting the original LUT and resetting smart masks. UI tests cover immediate parameter/asset capture, busy rejection, and recovery after a failed write. No user photos, settings, credentials, or live AI service are needed.
- Review found a second export ownership bug: iOS reused the same temporary path while Photos or sharing could still consume it. Added `TemporaryExportFile`, retained it through consumer completion, and tested same-name overlap plus independent cleanup. Also preserved initialization behavior for theme settings and removed the unused `Cube` alias.
- Final code review checked lookup cache keys against their inputs, retained Metal resources, the actor's lack of suspension points, value-based asset snapshots, provider lifetime, success/error cleanup, late-progress guards, and macOS/iOS export call sites. No unresolved findings remain within this change's scope.
- `swift test`: 18 tests, 15 passed, 3 skipped, 0 failures. The existing skips require an AI mock endpoint or Electron comparison fixtures. Identity rendering has maximum pixel difference 0.
- `MTL_DEBUG_LAYER=1 swift test --skip-build --filter 'RenderIsolationTests|ExportServiceTests|ExportTests'`: Metal API validation enabled; 9 tests passed, 0 failures.
- `swift build -c release --product LinseMac`: passed. Existing Swift 6 capture warnings in matching/mask recognition and deprecated UI APIs remain outside this change.
- The first full validation attempt ran out of disk space. Only reproducible project build caches were cleared with `swift package clean`; validation resumed sequentially.
- `bash scripts/check-ios.sh`: passed for the shared LinseCore/LinseUI code, including the iOS sharing and Photos call sites. Full simulator/device execution was not performed; the earlier Xcode app build was blocked by the locally missing iOS 18.5 platform.
