# Remaining Runtime Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address the remaining concurrency and deprecated-API findings, verify the current platforms, and support original-size exports beyond the GPU texture-size limit, as explicitly confirmed by the user.

**Architecture:** Keep the existing deployment targets and editing model. Give smart-mask detection its own actor and context, with request identity guarding UI completion. Use the available macOS screenshot API for the existing development helper. Oversized export reads bounded source regions and builds mip levels on the same global grid as the normal renderer. File-backed pixel buffers avoid copying whole output arrays; encoded results replace the destination only after successful completion.

**Tech Stack:** Swift 5.10 package mode, Xcode 16.4, SwiftUI, Metal, Core Image, ScreenCaptureKit, XCTest.

---

## Constraints and decisions

- Preserve the existing uncommitted edits in `AISettingsView.swift` and `IOSRoot.swift`; do not include unrelated changes in this commit.
- Keep macOS 14 and iOS 17 targets. Recommendations for newer toolchains in the SwiftUI skill do not change this project's compatibility requirements.
- Use a dedicated smart-mask service instead of an unchecked renderer/context wrapper or running Vision on the main actor. Publish only results belonging to the current source and request.
- Retain the existing editor architecture; migrating all state wrappers is unnecessary for these defects.
- The user explicitly selected original-size oversized export. Do not solve this by changing output dimensions.
- Do not download a simulator runtime silently. Report an unavailable runtime as a validation limit, and keep the existing SDK compilation check.

## Task 1: Smart-mask ownership and stale requests

Files: `Sources/LinseCore/SmartMaskService.swift`, `Sources/LinseUI/AppState.swift`, `Sources/LinseUI/AppState+Extras.swift`, `Tests/LinseUITests/SmartMaskTests.swift`.

1. Inject recognition for deterministic tests without Vision/model dependencies.
2. Test successful insertion, failure recovery, and a suspended old request completed after a source replacement.
3. Move recognition to a dedicated actor, remove `Box`, and guard completion by request identity and source.
4. Run the focused tests and compile using the project's concurrency checks.

## Task 2: Deprecated APIs

Files: `Sources/LinseUI/CanvasView.swift`, `Sources/LinseUI/MacRoot.swift`, `Sources/LinseUI/WindowSnapshot.swift`.

1. Replace the remaining deprecated one-argument `onChange` in the canvas.
2. Migrate the opt-in development snapshot helper to ScreenCaptureKit, retaining window-specific capture and exposing capture/write errors.
3. Verify current minimum targets and build the macOS product and shared iOS target.

## Task 3: Oversized export

1. Implement bounded source-region loading without silently resizing the output.
2. Preserve global mask, vignette, grain, and spatial-filter coordinates; compare forced source tiling against the whole-source path on manageable images.
3. Exercise dimensions above the real device texture limit, both export precisions, edge tiles, cancellation, and error recovery.

## Task 4: Review and verification

1. Re-review ownership, data lifetime, file preservation, pixel alignment, and unchanged user edits.
2. Run full tests, relevant Metal API validation, release build, and iOS SDK compilation.
3. Record observed results and actual remaining limits; commit only this task's changes.

## Evidence

- Smart-mask recognition now uses `SmartMaskService` with a request-local context; the unchecked `Box` and detached task capturing UI state are removed. Two tests cover failure/retry and an old suspended request completing after a new source/request has started.
- The canvas uses the supported `onChange` overload. The opt-in development screenshot helper uses `WindowSnapshot` and ScreenCaptureKit with window-specific filtering, actual pixel scale, and visible error handling. Existing `AISettingsView.swift` and `IOSRoot.swift` edits remain preserved and are excluded from this task's commit.
- `TiledImageSource` loads the original image and mip inputs in bounded regions. The renderer and tiled export share the same explicit Metal downsampler. Sharpness samples use global pixel interpolation to avoid differences caused by sampling differently sized textures.
- `MappedRaster` backs full output/mip pixels with temporary files. Space is reserved before mapping, paths are unlinked immediately, and `CGDataProvider` retains the mapping for the resulting image's lifetime. Per-tile autorelease pools and export-end cache cleanup bound transient resource lifetime.
- Export encoding occurs inside an isolated staging directory. An atomic rename replaces the destination after successful encoding and cancellation checks; failed rendering/encoding/cancellation preserve an existing file and remove temporary files.
- Invalid empty/infinite dimensions fail before allocating textures. Newly fallible mip allocation/encoding errors propagate through the renderer and UI.

### Review corrections and regression evidence

- Initial source-tiling parity tests exposed different low-frequency rounding. A shared Metal mip generator replaced the alternate downsampling path; fixture tolerances were not relaxed.
- Additional portrait tests exposed a few sharpness outliers at 19×4101. A diagnostic confirmed mip pixels were identical; explicit interpolation on the common global pixel grid fixed the normalized-sampler discrepancy. The temporary diagnostic was removed; the portrait regression remains.
- An encoding-failure test revealed ImageIO-created auxiliary files. Moving all encoding into a task-specific staging directory fixed their cleanup.
- Input tiling is compared against whole-source rendering at 256×192, 259×197, 257×5, 4101×19, and 19×4101, using identity, individual spatial filters, and combined color/spatial/mask effects, in both PNG and TIFF16 (50 comparisons). Existing limits remain maximum one 8-bit level and normalized 16-bit error ≤ 1/1024.
- Real dimensions beyond the device limit are exercised horizontally and vertically in all three export formats, with decoded dimensions and bit depth checked. Patterned 16389×17 and 17×16389 bitmap inputs are compared pixel-by-pixel, including translated input origins.
- Invalid extents, cancellation between tiles, failure recovery, and a JPEG encoding failure at 70000×1 preserve the existing destination. That same image can subsequently be encoded as PNG.
- The eleven independent Electron references are checked through RGBA8, Core Image, and CGImage input paths without regenerating fixtures.

### Platform coverage and remaining limits

- Shared iOS code compiled successfully using the installed SDK. `simctl list runtimes` reports no installed runtime, so iOS device/simulator execution was not performed. Deployment targets remain unchanged.
- The development screenshot helper was compile-checked; its opt-in capture was not run against the user's screen. ScreenCaptureKit manages the system's capture permission.
- Original-size export is no longer limited by a single GPU texture's dimensions. Export still requires sufficient temporary disk space and a format capable of encoding the requested dimensions; encoding failure preserves the destination.

### Final verification

- The full suite passed with Metal API validation enabled: 36 tests executed, 35 passed, one optional AI mock-endpoint test skipped, zero failures. The deterministic AI recovery and smart-mask tests ran successfully.
- The macOS release product `LinseMac` built successfully. Shared `LinseUI` code compiled successfully against the installed iOS SDK. Neither build reported warnings or errors.
- `git diff --check` passed, and the embedded shader exactly matches `Shaders.metal`.
- Final review covered request ownership, mapped-buffer lifetime, global sampling coordinates, cancellation, and destination-file preservation. No blocking finding remains within this repair scope; the platform and format limits above still apply.
