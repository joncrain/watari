# Pairing & Local Network

Watari connects two Macs over TLS on a chosen TCP port (default **59234**). Trust is the Curve25519 key exchanged in Hello and pinned after pairing — not the LAN and not Bonjour.

## Root cause of NWError -9810

`NWError -9810` (`errSSLInternal`) appeared when the listener used `NWProtocolTLS.Options()` **without a local identity** and the client expected a normal TLS handshake. Network.framework then aborted before the Watari Hello frame.

**Fix:** each install creates a self-signed transport identity (`WatariTLS`) for the listener; the client accepts that cert via a verify block. Application trust remains the Hello public-key pin after pairing.

## Connect UX

1. **Nearby (primary when allowed)** — Bonjour `_watari._tcp`. Tap a Mac name to connect (Screen Sharing–style pick list). Requires Listen on the source Mac and the same link-local segment with mDNS.
2. **Host / port (always available)** — hostname, FQDN, or IP + port. Use on VLANs / Managed networks where Nearby is off.

Managed defaults (`DenyBonjour`, `ManagedMode`, or `DiscoveryMode=explicit|off`) hide Nearby and stop Bonjour advertising.

## Permissions (not Screen Sharing)

Watari does **not** use the Screen Sharing / Remote Management privilege. Typical prompts:

| Prompt | Why |
|--------|-----|
| **Local Network** | Browse Nearby and open outbound peer connections |
| **Firewall** | Allow inbound Listen on the chosen port |
| **Files and Folders** / open panel | Security-scoped bookmarks for offered / receive folders |

### System Settings checklist

1. **Privacy & Security → Local Network** — enable Watari on both Macs.
2. **Network → Firewall** — allow Watari (or open TCP 59234 between the two hosts).
3. Source Mac: Watari → **Settings → Listen for peers** on, leave the app open, and offer at least one folder (or set a receive folder so Listen can start).
4. Destination Mac: Connect via Nearby or host/port, then choose folders from the peer’s offer catalog.

## Failure copy map

| Symptom | Likely cause |
|---------|----------------|
| Secure connection failed (TLS) / -9810 | Old build without TLS identity; update both Macs |
| Connection refused | Listen off, wrong port, or firewall |
| Couldn’t reach Watari… | Peer not listening / wrong host |
| Local Network access is off | Enable Watari under Local Network privacy |
| No Nearby Macs | Different VLAN, mDNS blocked, or Managed Nearby off — use host/port |

See also [enterprise.md](enterprise.md) for MDM keys.
