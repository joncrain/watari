---
name: macos-design
description: Use when designing or reviewing Watari's macOS interface structure — sidebars, toolbars, inspectors, Settings, menus, and Human Interface Guidelines. Prefer before SwiftUI layout work.
---

# macOS design (HIG) for Watari

## Structure

- Use a **NavigationSplitView** (sidebar + detail + optional inspector), not a phone tab bar stretched to desktop.
- Provide **Show/Hide Sidebar** via View menu / toolbar; do not hide the sidebar by default.
- Put app preferences in a **Settings** scene (standard Settings menu item), not a fake System Settings clone.
- Group Settings with `TabView` tabs: General, Network, Permissions, Exclusions.
- Primary actions live in the **toolbar**: Preview, Start, Stop.
- Use a **sheet** for Connect (host/port first; Nearby as a second tab when Bonjour is enabled).

## System citizenship

- Respect the user’s **accent color** for sidebar symbols and controls.
- Semantic colors and system materials only.
- SF Symbols for iconography.
- Menus and keyboard shortcuts for Preview, Start, Stop.
- Explain a permission **before** the system TCC prompt; never invent a parallel permission UI that looks like System Settings.

## Content

- One job per view region: folders, preview, or policy — not all three fighting.
- Empty and error states are first-class screens (see DESIGN.md).
- Enterprise copy stays precise; avoid cute metaphors in Managed mode footnotes.
