---
name: swift-macos
description: Use when writing or reviewing Swift for Watari — portable WatariCore, macOS app targets, concurrency, bookmarks, file metadata, and transfer code. Prefer before any Swift edit in this repo.
---

# Swift / macOS for Watari

## Split

- **`WatariCore`** — pure Swift, no AppKit/SwiftUI/Network Bonjour. Must build and test on Linux.
- **`App/`** — SwiftUI, bookmarks, Network.framework, Bonjour, Keychain for peer keys, `copyfile` / Foundation file APIs that need Darwin.

Never import Apple-only discovery into the core package.

## Language

- Swift 6 language mode; treat concurrency warnings as errors in spirit.
- Prefer `async`/`await` and structured tasks over scattered callbacks.
- No force-unwraps in production paths; surface failures as typed errors / log entries.

## Files & permissions

- Security-scoped bookmarks for every user-chosen root; start/stop access around I/O; refresh stale bookmarks.
- Do not request Full Disk Access in v1 unless PRODUCT.md changes.
- Symlinks: copy as links; never follow out of the selection.
- Skip sockets, devices, named pipes; log skips.
- Denylist is mandatory even inside a selection (keychains, TCC DB, profiles).
- Use `copyfile` / equivalent fidelity ideas on Darwin; do **not** shell out to `rsync` or `cp`.

## Errors

- Map errno and TCC denials to stable reason codes in the job log.
- Never silent-skip without a log line.

## Networking (App)

- Explicit host/port is the primary path; Bonjour is optional Nearby.
- TLS after pairing with pinned keys; no plaintext fallback.
- Honor managed preference keys from `docs/enterprise.md`.
