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
- **After connect (destination):** choose folders → path mapping → Start.
- **After Start:** calm **Transfer complete** summary (folders, files, bytes, duration, skip/unchanged, remaps).
- **Toolbar:** custom sidebar/inspector toggles only — no system NavigationSplitView `>>`.
- **Sidebar + inspector:** Hidden/collapsed by default; reveal via toolbar.
- **Toolbar:** Connect; after peer — Start (pull) / Stop; sidebar/inspector toggles.
- **Services:** Dock shows a live miniature of the source Mac’s Dock when connected; other services remain coming soon.
- **Settings:** Receive folder; Listen/port + same offer list for power users.
- **Connect sheet:** Nearby list primary when enabled; host / port under “Connect by host / port”.


## Required states (real screens)

1. No folders yet  
2. Waiting for peer  
3. Connected — choose folders / Start  
4. Copying (progress under the list)  
5. Finished with exceptions  
6. Peer gone mid-copy  

## Copy tone

Short, specific, permission-aware. Explain *why* before a system TCC prompt. Label risky options (keep numeric uid) next to the control in Settings. Managed-mode strings stay IT-readable.

## Anti-patterns

- Sidebar + inspector chrome for the default transfer job  
- Competing stub rows next to a live Dock preview (Dock is live; other Services stay muted)  
- Cards, badge spam, or floating promo chips  
- Fake System Settings chrome  
- Glow, neon, or “AI purple” skins  
- Hiding Bonjour as the only discovery path  
- A user-facing Preview dry-run control (Start is enough; `PreviewDiff` stays internal)