# Enterprise guide

Watari is built for segmented networks and managed Macs. Bonjour is optional. Trust comes from pairing and TLS, not from the LAN.

## Managed mode

When managed preference keys are present (MDM / configuration profile / `defaults` domain `app.watari.mac`), Watari treats the install as **Managed**:

- Discovery defaults to **explicit only** (Bonjour Nearby off).
- Network and permission locks from MDM override the UI where specified.
- The Settings Network pane shows a “Managed by organization” footnote for locked keys.

Domain: `app.watari.mac`

| Key | Type | Meaning |
|-----|------|---------|
| `ManagedMode` | Boolean | Force managed defaults |
| `ListenEnabled` | Boolean | Allow inbound listen |
| `ListenPort` | Integer | Fixed listen port |
| `BindAddress` | String | `localhost` · `lan` · IP |
| `DiscoveryMode` | String | `off` · `nearby` · `explicit` |
| `BandwidthLimitBytesPerSecond` | Integer | 0 = unlimited |
| `IdleTimeoutSeconds` | Integer | Drop idle peers |
| `MaxConcurrentTransfers` | Integer | Cap parallel file sends |
| `LockPermissionPolicy` | Boolean | Disable permission toggles in UI |
| `StripQuarantine` | Boolean | Force quarantine xattr policy |
| `KeepNumericOwner` | Boolean | Force owner remap behavior |
| `PeerAllowlist` | Array of dicts | Pre-seed pinned peers (`name`, `publicKey`, `host`, `port`) |
| `DenyBonjour` | Boolean | Hard-disable Nearby |

### DLP (planned — keys reserved)

Configurable data-loss controls for a future release. The portable `DLPPolicy` model and preview skip reason (`dlp`) exist in `WatariCore` today; **full job enforcement and Settings UI ship later**. When `DLPEnabled` is true, MDM can steer what may cross the corridor without relying on a cloud DLP broker.

| Key | Type | Meaning |
|-----|------|---------|
| `DLPEnabled` | Boolean | Turn DLP evaluation on |
| `DLPLocked` | Boolean | Hide/disable user overrides in Settings |
| `DLPBlockedExtensions` | Array of strings | Extensions that must not transfer (`pem`, `p12`, `key`, …) |
| `DLPBlockedPathSuffixes` | Array of strings | Relative path suffixes / segments to block |
| `DLPBlockedNameSubstrings` | Array of strings | Case-insensitive filename tokens to block |
| `DLPMaxFileBytes` | Integer | Max single-file size; `0` = unlimited |
| `DLPRequireAllowlistedPeer` | Boolean | Only pinned / MDM allowlisted peers |
| `DLPBlockOutbound` | Boolean | Freeze sends (receive-only) |
| `DLPBlockInbound` | Boolean | Freeze receives (send-only) |
| `DLPPolicyLabel` | String | Label echoed into audit events for SIEM |

**Design notes for IT**

- DLP decisions appear in Preview before bytes move (same as denylist).
- Built-in denylist (keychains, TCC, profiles) always applies; DLP is additive.
- No content inspection / cloud upload in the first DLP cut — path, name, extension, size, direction, and peer allowlist only. Deeper classifiers can layer on later without changing these keys.
- Audit `reason` codes will include `dlp` plus the verdict (`blockExtension`, `blockOutbound`, …).

Example payload fragment:

```xml
<key>DLPEnabled</key><true/>
<key>DLPLocked</key><true/>
<key>DLPBlockedExtensions</key>
<array>
  <string>pem</string>
  <string>p12</string>
  <string>key</string>
</array>
<key>DLPRequireAllowlistedPeer</key><true/>
<key>DLPPolicyLabel</key><string>corp-mac-corridor-v1</string>
```

## Network checklist for IT

1. Open the chosen TCP port between the two Macs (same VLAN or routed). Default **59234**.
2. Prefer FQDN or management IP in tickets; ship a connection profile JSON if helpful.
3. Leave Bonjour off unless both Macs share a link-local segment with mDNS allowed.
4. **Preapprove Application Firewall** for Watari on source Macs (MDM firewall payload or `socketfilterfw --add` / `--unblockapp` on the installed `.app`). The first inbound Connect otherwise shows an **admin** “accept incoming connections” dialog. Full Disk Access does **not** cover this.
5. Preapprove **Local Network** for `app.watari.mac` via Privacy / TCC profiles where available.
6. Pair once; revoke the peer key when a machine leaves the fleet.
7. Export the exception log after large jobs for change records.
8. Prefer Developer ID–signed + notarized builds for fleet installs so Firewall does not re-prompt on every ad-hoc Debug hash.

## Connection profile (export/import)

```json
{
  "version": 1,
  "displayName": "Lab Mac B",
  "host": "mac-b.lab.example.com",
  "port": 59234,
  "publicKey": "<base64-ed25519-spki>",
  "discovery": "explicit"
}
```

## Audit log fields

Each job writes structured events (JSON Lines):

| Field | Description |
|-------|-------------|
| `timestamp` | ISO-8601 |
| `jobId` | UUID |
| `peerId` | Paired peer id |
| `path` | Relative path within selection |
| `action` | `copy` · `update` · `keepBoth` · `skip` · `unchanged` · `exception` |
| `reason` | Machine-readable code (`denylist`, `tcc`, `symlink_skip`, `acl_dropped`, …) |
| `bytes` | Payload size when applicable |
| `permissionDelta` | Summary of metadata policy applied |

## What Watari will never copy

Even inside a selected folder:

- Keychain databases and related paths  
- TCC database  
- Configuration profiles / Managed Preferences payloads used for MDM identity  

Selecting `~/Library` or `/Library` shows an explicit warning: this is not system migration.
