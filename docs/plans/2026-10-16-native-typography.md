# Native typography refinement

Scope: the user explicitly selected the SwiftUI version of Linse. The reference screenshot came from the Electron version; its temporary typography edits were reverted. Existing edits in `AISettingsView.swift`, `IOSRoot.swift`, and the Electron renderer remain preserved.

Use the system font with shared semantic text styles. Give the three-step guide and section headings stronger weight, remove excessive tracking from group headings, and improve the contrast of explanatory labels. Render shortcuts in the normal system face with separated symbols and a subtle key label. Keep monospaced digits for numerical content.

Verification: debug and release macOS builds passed, and the local app bundle was rebuilt and launched. The minimum-width window was visually checked: guide titles fit, key labels remain separate, and sidebar headings are legible. The accessibility tree exposes the guide's action names and shortcut help without reading decorative step numbers. Shared iOS code compiled successfully; iOS runtime behavior was not tested. No rendering or editing logic changed.
