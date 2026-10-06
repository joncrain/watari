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

- **First screen (destination):** Connect / Nearby only — pull flow. “Offer folders from this Mac…” is a secondary link.
- **Source when a peer connects inbound:** switches to **Prepare this Mac** (offer catalog + Add folder + Listen).
- **After connect (destination):** choose folders → home mapping → Preview / Start.
- **After Start:** calm **Transfer complete** summary (folders, files, bytes, duration, skip/unchanged, remaps).
- **Toolbar:** custom sidebar/inspector toggles only — no system NavigationSplitView `>>`.
- **Sidebar + inspector:** Hidden/collapsed by default; reveal via toolbar.
- **Toolbar:** Connect; after peer — Preview / Start (pull) / Stop; sidebar/inspector toggles.
- **Settings:** Receive folder; Listen/port + same offer list for power users.
- **Connect sheet:** Nearby list primary when enabled; host / port under “Connect by host / port”.


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
