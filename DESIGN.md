# Design

## Platform

macOS utility (Operate mode). HIG structure first; brand in precise details.

## Visual world

Native Mac tool in the spirit of first-party utilities — Migration Assistant calm, not a ported iPhone layout or SaaS shell.

- **Materials:** System window chrome, standard Settings scene. No persistent sidebar or inspector by default.
- **Color:** Semantic system colors (`label`, `secondaryLabel`, `separator`, `controlBackground`, window backgrounds). Interactive accent follows the **user’s system accent**. No custom purple gradient brand.
- **Type:** SF Pro / system text styles. No decorative display face in the app chrome.
- **Icons:** SF Symbols only.
- **Motion:** Light expand/collapse; honor Reduce Motion.
- **Dark Mode:** First-class; verify both appearances.

## Composition

- **Main (default):** Centered title (“Choose what to transfer”), short subtitle, **one bordered hierarchical list** (Users → current user → Desktop/Documents/Downloads/Pictures/Movies/Music/Public), plus sibling **Services / Dock / Finder** stubs (Coming soon). No Library / SystemData / tmp. Footer (“X selected to transfer. Y available on …”). Brand name **Watari** stays in the window title only.
- **Sidebar + inspector:** `NavigationSplitView` and inspector exist but are **hidden/collapsed by default**; reveal via toolbar.
- **Toolbar:** Preview / Start when a peer is ready; Connect otherwise; sidebar/inspector toggles. Stop only while copying.
- **Selection:** Checkbox / row click toggles standard home folders directly (one-time home security scope if the sandbox requires it — never a per-folder open panel for these locations).
- **Connect sheet:** Host / port primary; Nearby (Bonjour) secondary tab when enabled.
- **Settings:** General · Permissions (conflict + ownership; Advanced for the rest) · Exclusions · DLP.

## Required states (real screens)

1. No folders yet  
2. Waiting for peer  
3. Preview ready (compact summary under the list)  
4. Copying (progress under the list)  
5. Finished with exceptions  
6. Peer gone mid-copy  

## Copy tone

Short, specific, permission-aware. Explain *why* before a system TCC prompt. Label risky options (keep numeric uid) next to the control in Settings. Managed-mode strings stay IT-readable.

## Anti-patterns

- Sidebar + inspector chrome for the default transfer job  
- Stub Services / Dock / Finder sections competing with the folder tree  
- Cards, badge spam, or floating promo chips  
- Fake System Settings chrome  
- Glow, neon, or “AI purple” skins  
- Hiding Bonjour as the only discovery path  
