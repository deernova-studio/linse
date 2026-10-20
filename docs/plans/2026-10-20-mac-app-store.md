# Mac App Store Implementation Plan

**Goal:** Prepare Linse for its first free Mac App Store release on Apple Silicon.

**Architecture:** Add a sandboxed Xcode macOS app target referencing the existing LinseUI package and Mac entry point. Keep the Developer ID DMG workflow separate. Put AI photo consent in shared application state so every UI and keyboard entry point is covered.

**Tech Stack:** Swift 5.10+, SwiftUI, App Sandbox, Xcode 16.4+, App Store Connect, manually triggered GitHub Actions.

## Scope and decisions

- First release is free, without In-App Purchase (confirmed by the owner).
- Pricing base country is China mainland (CNY), as requested by the owner.
- Keep macOS 14, arm64 only, and iOS 17 shared-code compatibility.
- Mac settings remain local JSON. Sandboxed builds use their container; no Keychain migration.
- AI photos require explicit consent for each request, naming the configured recipient. Cancel or changed photos/settings must prevent transmission.
- Strip image metadata from AI previews. Offline matching remains available without AI credentials.
- Do not publish a store version before its actual build and listing are ready and checked.

## Implementation

1. Add `macOS/Linse.xcodeproj`, shared scheme, sandbox entitlements, icon assets, privacy manifest and archive/export options. Reuse `Sources/LinseMac/LinseApp.swift`.
2. Add a local archive/build verification command and a manually triggered store upload workflow. Validate arm64, minimum OS, sandbox and signing; keep credentials out of artifacts.
3. Fix export staging for user-selected sandbox destinations using the system replacement directory. Test existing-file preservation, failure and cancellation.
4. Gate AI matching behind a request bound to the exact source, target and AI settings. Add a compact consent sheet and an accessible in-app privacy explanation.
5. Add tests for no transmission before approval, cancellation, stale approvals, changed provider and metadata removal.
6. Prepare store description, privacy/support pages, review instructions and screenshots from the actual app. Confirm public contact, hosting and distribution territories with the owner before submitting those details.
7. Create the Apple app record, configure free pricing, obtain App Store distribution signing, then upload and validate the archive if account access permits.

## Verification

- `swift test`
- `bash scripts/check-ios.sh` (shared code only)
- Xcode macOS arm64 archive/build with sandbox enabled
- Live sandboxed app import, offline matching, export, settings and AI consent checks
- Workflow syntax and archive validator tests
- Inspect actual App Store Connect status and build processing before reporting an upload

## External prerequisites

Only a Developer ID Application certificate exists locally at the start. App Store distribution credentials are separate. A public privacy/support URL, supported territories and a reviewer-accessible AI service still need to be settled. No passwords or private keys belong in this repository.

## Verified progress — 2026-10-20

- Created Bundle ID `app.linse.mac` and App Store Connect record `6824873396`.
- Archived and exported version `0.3.0 (14)` using Xcode automatic signing and a Cloud Managed Apple Distribution identity. Verified the exported PKG installer signature and the app payload's distribution signature, sandbox, arm64 architecture and macOS 14 minimum.
- Apple upload completed successfully at 18:04 China time. App Store processing/review remains a separate step.
- Swift tests: 79 executed, 1 skipped, no failures. iOS shared code compiled. Python release validation: 14 tests passed. Workflow lint and shell syntax checks passed.
- Live sandbox smoke test: imported two local fixture images through the file picker, matched offline, exported JPEG outside the container, replaced the test output successfully, saved JSON configuration inside the container, viewed privacy text, cancelled photo sharing, and cleared the temporary test key.
- Store description and manual-release option saved; privacy/support web pages remain local drafts pending confirmation of public contact information and hosting.
- The GitHub store upload workflow is prepared but its separate distribution secrets have not been configured.
