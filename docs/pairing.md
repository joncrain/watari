# Pairing & Local Network

Watari connects two Macs over TLS on a chosen TCP port (default **59234**). Trust is the Curve25519 key exchanged in Hello and pinned after pairing — not the LAN and not Bonjour.

## Root cause of NWError -9810 / -9816

`NWError -9810` (`errSSLInternal`) appeared when the listener used `NWProtocolTLS.Options()` **without a local identity** and the client expected a normal TLS handshake.

`NWError -9816` (server closed / bad cipher) appeared when:

1. Cleartext Bonjour “resolve” TCP hit the TLS listener on launch, or
2. TLS identity was taken from the **login keychain** (a loose `kSecClassIdentity` query could resolve an Apple Development signing identity — prompting for the user’s “dev key” and failing the handshake).

**Fix:** each install stores a self-signed **RSA** PKCS#12 under Application Support and loads it into an **app-owned file keychain** (never the login keychain). Clients accept the transport cert via a verify block. Application trust remains the Hello public-key pin after pairing.

## Connect UX

1. **Nearby (primary when allowed)** — Bonjour `_watari._tcp`. Tap a Mac name to connect (Screen Sharing–style pick list). Requires Listen on the source Mac and the same link-local segment with mDNS.
2. **Host / port (always available)** — hostname, FQDN, or IP + port. Use on VLANs / Managed networks where Nearby is off.

Managed defaults (`DenyBonjour`, `ManagedMode`, or `DiscoveryMode=explicit|off`) hide Nearby and stop Bonjour advertising.

## Permissions (not Screen Sharing)

Watari does **not** use the Screen Sharing / Remote Management privilege. Typical prompts:

| Prompt | Why | Admin password? |
|--------|-----|-----------------|
| **Local Network** | Browse Nearby and open outbound peer connections | Usually no (Privacy toggle) |
| **Firewall — “accept incoming connections?”** | Source is Listening; destination’s Connect hits TCP on the listen port | **Yes, often** — expected on first allow |
| **Files and Folders** / open panel | Security-scoped bookmarks for offered / receive folders | No |
| ~~Full Disk Access~~ | **Not requested in v1** — bookmarks only | — |

### Source admin prompt when destination hits Connect

That dialog is almost certainly **Application Firewall**, not keychain and not FDA. It appears when an inbound connection reaches Watari’s listen socket (default **59234**) and Watari is not yet allowed for incoming traffic.

- **Expected:** yes, once per app binary identity while Firewall is on.
- **Debug / ad-hoc builds** (`codesign` Signature=adhoc): macOS often asks **again after every rebuild** because the code directory hash changed.
- **Not fixed by Full Disk Access.** FDA does not authorize firewall or Local Network; PRODUCT.md keeps FDA out of v1 on purpose.
- **Keychain “dev key”** was a separate bug (login-keychain TLS identity) and is fixed — Watari no longer uses the login keychain for transport TLS.
- **Keychain “Imported Private Key” / “Watari Peer”:** that is Watari’s self-signed TLS transport key in the app-owned file keychain — **not** Apple Development. If an older Debug build prompts, click **Always Allow** once; current builds set the key ACL so Listen should not ask again.

### How to preapprove (no FDA)

1. **Manual (this Mac):** System Settings → **Network → Firewall → Options…** → add **Watari** → Allow incoming. Or click Allow on the dialog the first time Connect succeeds in reaching Listen.
2. **IT / MDM:** ship an Application Firewall payload (or script `socketfilterfw --add` / `--unblockapp` on the Watari.app path) so inbound is allowed before users pair. Also allow **Local Network** for `app.watari.mac` via Privacy TCC profiles where your MDM supports it.
3. **Distribution (later):** Developer ID **codesign + notarize** so Gatekeeper and Firewall treat the app as a stable, identified binary — fewer repeat prompts than ad-hoc Debug builds.

### System Settings checklist

1. **Privacy & Security → Local Network** — enable Watari on both Macs.
2. **Network → Firewall** — allow Watari for incoming (source especially). Open TCP **59234** between hosts if you use a hardware firewall.
3. Source Mac: Watari → **Settings → Listen for peers** on, leave the app open, and offer at least one folder (or set a receive folder so Listen can start).
4. Destination Mac: Connect via Nearby or host/port, then choose folders from the peer’s offer catalog.

## Failure copy map

| Symptom | Likely cause |
|---------|----------------|
| Secure connection failed (TLS) / -9810 | Old build without TLS identity; update both Macs |
| Secure connection failed (TLS) / -9816 | Often cleartext traffic hitting the TLS port, or a broken listener identity; update both Macs |
| Connection refused | Listen off / wrong port / Happy Eyeballs race (fixed: wait for `.ready`). Not usually the macOS firewall |
| Couldn’t reach Watari… | Peer not listening / wrong host |
| Local Network access is off | Enable Watari under Local Network privacy |
| No Nearby Macs | Different VLAN, mDNS blocked, or Managed Nearby off — use host/port |

See also [enterprise.md](enterprise.md) for MDM keys.
