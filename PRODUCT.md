# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Stack

Swift 6, SwiftUI (macOS 14+), portable `WatariCore` package (Linux-testable), Network.framework + optional Bonjour on Mac, security-scoped bookmarks, XcodeGen for the app project.

## Users

**Primary (priority 1):** People moving or backing up chosen folders between two Macs they control — home desks, lab benches, or replacement machines — who want a clear transfer plan and a log, not a full account migration.

**Secondary (priority 2):** IT / Mac admins who need explicit host/port connect on segmented networks, MDM-toggleable Nearby discovery, and an audit trail of permission exceptions — without another Migration Assistant that breaks profiles.

**Tertiary (priority 3):** Power users pairing Watari with Genkan-family tools who care about metadata fidelity (mode, xattrs, ACLs) with an explicit policy.

## Product Purpose

Watari (渡り) is the connecting passage between two Macs: one-way folder backup first, automatic two-way sync later. Success means files the user chose arrive with a clear permission story, enterprise tooling stays untouched, and networking is predictable on VLANs where Bonjour fails.

## Positioning

Not Migration Assistant. Not cloud sync. A calm, first-party-feeling Mac utility for **chosen folders**, **visible permission policy**, and **configurable peer networking** (TLS after pairing). Sibling spirit to Genkan (玄関), the threshold.

## Operating Context

- Both machines run Watari.
- Sandboxed; folders added via the system open panel; security-scoped bookmarks.
- Full Disk Access is not requested in v1 (bookmarks only). FDA does **not** replace Firewall or Local Network approval when the source Listens.
- First inbound Connect may trigger macOS Application Firewall’s “accept incoming connections” dialog (often with admin password); preapprove via Firewall settings / MDM, or reduce repeats with Developer ID + notarization later.
- Linux CI runs `WatariCore` tests only; UI polish is verified on a Mac.

## Capabilities and Constraints

**v1 ships**

- One-way copy of selected folder trees to a paired peer.
- **Source prep:** with Listen on, the main window shows the offer catalog and **Add folder…** (destination only chooses what to pull).
- **Destination transfer:** first screen is Connect/pull; after Connect, select offered folders. **Under-home** offers mirror into the destination home; **custom Add folder** paths outside the source home keep their **full absolute path**. **Start** pulls (no Preview control). Then a **transfer complete** summary. Source Mac emphasizes Prepare/offer when a peer connects inbound.
- Internal `PreviewDiff` still decides copy/update/skip during Start; not a user-facing Preview step.
- **Dock POC:** source includes Dock layout in the offer catalog; destination shows a live miniature Dock strip in Services (apply later).
- Permission policy: remap owner to receiving user by default; keep mode; ACL/xattr rules; strip quarantine by default.
- Built-in denylist: keychains, TCC database, configuration profiles.
- Connect via Nearby device list (Bonjour) when discovery allows, or hostname / FQDN / IP + port; TLS with pinned peer keys after pairing.
- Configurable listen, bind, port, discovery mode, timeouts, optional bandwidth cap.
- Nearby defaults on for consumer installs; off under Managed defaults (`DenyBonjour` / explicit discovery).
- Exception log exportable for audit.

**Must not**

- Migrate accounts, apps, keychains, profiles, or MDM state.
- Follow symlinks out of the selection.
- Offer plaintext transfer.
- Require Bonjour for a successful job.

## Brand Commitments

- **Name:** Watari (渡り). Pronounce roughly “wah-tah-ree.”
- **Voice:** Calm, precise, admin-readable. Explain permissions before system prompts. No startup hype.
- **Visual:** Native macOS utility — Migration Assistant calm (single transfer panel), system materials, SF Symbols, user accent color, semantic colors. Brand in the window title; polish in states and copy, not a custom SaaS brand skin.
- **Family:** Genkan = threshold; Watari = crossing / connecting corridor.

## Product Principles

1. **Chosen folders only** — bookmarks beat Full Disk Access.
2. **Permissions are the product** — surface permission outcomes in the transfer plan and log.
3. **Connect without guessing** — Nearby when the LAN allows; host/port always works and is required on Managed / segmented nets.
4. **Pin trust** — TLS after pairing; revoke peers.
5. **Stay out of identity** — never a second Migration Assistant.

## Accessibility & Inclusion

VoiceOver labels on all primary controls; Reduce Motion honored; keyboard equivalents for Start, Stop; Dynamic Type / sidebar icon size respect where system provides them.

## Later

- Run the same one-way job when files change; then two-way sync with conflicts.
- Full Disk Access opt-in; notarized distribution; richer MDM UI.
- **Configurable DLP (MDM):** block by extension, path, name, size, job direction, and allowlisted peers; locked policy; SIEM label in the audit log. Model and preference keys are reserved in `WatariCore` / `docs/enterprise.md`; enforcement UI and transfer gates follow in a dedicated release.
