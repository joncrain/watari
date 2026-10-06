# Watari

**Watari** (渡り) — the crossing between two Macs.

Enterprise-ready one-way folder backup: chosen folders only, a visible permission policy, and configurable networking. Named for the Japanese connecting passage between buildings; a sibling spirit to Genkan (玄関), the threshold.

This is **not** Migration Assistant. Watari never migrates user accounts, applications, keychains, configuration profiles, or MDM state.

## Status

v1 goal: one Mac sends chosen folders to another over TLS after pairing. Preview and exception log before and after. Two-way sync is a later destination; the manifest and permission policy are shaped for it.

## Layout

| Path | Purpose |
|------|---------|
| `Sources/WatariCore/` | Portable core (Linux + macOS): metadata, denylist, permission policy, preview, transfer codec |
| `Tests/WatariCoreTests/` | Unit tests runnable on Linux |
| `App/` | SwiftUI macOS app (build with Xcode / XcodeGen on a Mac) |
| `project.yml` | XcodeGen project for the Mac app |
| `docs/enterprise.md` | Managed mode, network keys, audit fields |
| `.cursor/skills/` | `swift-macos`, `macos-design`, `macos-ui` |

## Requirements

- **Core tests:** Swift 6.0+ on Linux or macOS (`swift test`)
- **App:** macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
swift test
# On a Mac:
xcodegen generate
open Watari.xcodeproj
```

## Product principles

1. Chosen folders only — security-scoped bookmarks, no Full Disk Access by default.
2. Permissions are a product surface — preview what metadata will arrive.
3. Explicit connect first — hostname/IP + port; Bonjour is optional Nearby.
4. TLS after pairing — pin peer keys; no trust-the-LAN.
5. Stay out of enterprise identity — never touch profiles, TCC DB, or keychains.

MDM-configurable **DLP** keys are reserved for a later release (extension/path/size/direction/peer gates). See [docs/enterprise.md](docs/enterprise.md).

## License

Private — coordinate before redistribution.
