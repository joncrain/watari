---
name: macos-ui
description: Use when polishing Watari UI quality — hierarchy, empty/error states, permission copy, accessibility, and Operate-mode craft. Points at macos-design for HIG structure.
---

# macOS UI quality for Watari

Operate mode: the person completes a backup job. Scanability and native affordances outrank expression. Read [macos-design](../macos-design/SKILL.md) for structure.

## Quality bar

- Hierarchy: sidebar orientation → main task → inspector policy.
- Every required state in DESIGN.md must be a real, reachable UI (not a TODO placeholder in shipping paths).
- Permission copy names the consequence (“files will belong to *this* Mac’s user”) next to the control.
- Exception counts are visible after Preview and after the job; drill-in lists paths and reason codes.
- Progress is cancelable (Stop); never block quitting without saying why.

## Accessibility

- VoiceOver labels on toolbar buttons, folder rows, preview actions, and peer status.
- Honor Reduce Motion.
- Don’t rely on color alone for copy vs skip vs exception — use symbols + text.

## Anti-slop

- No web-shaped cards for static summary content when a labeled form / list will do.
- No emoji status.
- No glow, glassmorphism kits, or custom typefaces in chrome.
- Nearby discovery never outranks explicit Connect in the default layout.
