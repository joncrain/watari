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

- **Main (default):** Centered title (“Choose what to transfer”), short subtitle, **one bordered hierarchical list** (Users → current user → home folders), footer (“X selected to transfer. Y available on …”). Brand name **Watari** stays in the window title only.
- **Toolbar:** Minimal — Preview / Start when a peer is ready; Connect otherwise. Stop only while copying.
- **Connect sheet:** Host / port primary; Nearby (Bonjour) secondary tab when enabled.
- **Settings:** General · Permissions (conflict + ownership; Advanced for the rest) · Exclusions · DLP. Policy stays out of the main window.

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
