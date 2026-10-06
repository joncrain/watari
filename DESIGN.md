# Design

## Platform

macOS utility (Operate mode). HIG structure first; brand in precise details.

## Visual world

Native Mac tool in the spirit of first-party utilities — not a ported iPhone layout, not a SaaS marketing shell.

- **Materials:** System window chrome, sidebar, toolbar, inspector, standard Settings scene.
- **Color:** Semantic system colors (`label`, `secondaryLabel`, `separator`, `controlBackground`, window backgrounds). Interactive accent follows the **user’s system accent**. No custom purple gradient brand.
- **Type:** SF Pro / system text styles. No decorative display face in the app chrome.
- **Icons:** SF Symbols only; sidebar icons respect system accent unless a fixed color carries meaning (e.g. error).
- **Motion:** System transitions; honor Reduce Motion with crossfades instead of large slides.
- **Dark Mode:** First-class; verify both appearances.

## Composition

- **Sidebar:** This Mac, paired peers, jobs.
- **Main:** Folder list for the job → preview table.
- **Inspector:** Permission policy summary + exception count.
- **Toolbar:** Preview, Start, Stop (with keyboard equivalents).
- **Connect sheet:** Host / port primary; Nearby (Bonjour) secondary tab when enabled.
- **Settings:** General · Network · Permissions · Exclusions.

## Required states (real screens)

1. No folders yet  
2. Waiting for peer  
3. Preview ready  
4. Copying (progress)  
5. Finished with exceptions  
6. Peer gone mid-copy  

## Copy tone

Short, specific, permission-aware. Explain *why* before a system TCC prompt. Label risky options (keep numeric uid) next to the control. Managed-mode strings stay IT-readable.

## Anti-patterns

- Cards in the hero of empty states when a plain explanation + one button suffices  
- Fake System Settings chrome  
- Glow, neon, or “AI purple” skins  
- Hiding Bonjour as the only discovery path  
- Badge spam / floating promo chips on the main window  
