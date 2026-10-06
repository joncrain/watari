import Foundation
import WatariCore

enum ManagedDefaults {
    private static var suite: UserDefaults {
        UserDefaults(suiteName: ManagedPreferenceKey.domain) ?? .standard
    }

    static var managedMode: Bool {
        suite.object(forKey: ManagedPreferenceKey.managedMode) as? Bool ?? false
    }

    static var denyBonjour: Bool {
        if let v = suite.object(forKey: ManagedPreferenceKey.denyBonjour) as? Bool { return v }
        return managedMode
    }

    static var lockPermissionPolicy: Bool {
        suite.object(forKey: ManagedPreferenceKey.lockPermissionPolicy) as? Bool ?? false
    }

    static func applyOverrides(to network: inout NetworkConfig, policy: inout PermissionPolicy) {
        let d = suite
        if let v = d.object(forKey: ManagedPreferenceKey.listenEnabled) as? Bool {
            network.listenEnabled = v
        }
        if d.object(forKey: ManagedPreferenceKey.listenPort) != nil {
            network.listenPort = d.integer(forKey: ManagedPreferenceKey.listenPort)
        }
        if let mode = d.string(forKey: ManagedPreferenceKey.discoveryMode),
           let parsed = DiscoveryMode(rawValue: mode) {
            network.discoveryMode = parsed
        }
        if denyBonjour, network.discoveryMode == .nearby {
            network.discoveryMode = .explicit
        }
        if let bind = d.string(forKey: ManagedPreferenceKey.bindAddress) {
            switch bind {
            case "localhost": network.bindMode = .localhost
            case "lan": network.bindMode = .lan
            default:
                network.bindMode = .address
                network.bindAddress = bind
            }
        }
        if d.object(forKey: ManagedPreferenceKey.bandwidthLimit) != nil {
            network.bandwidthLimitBytesPerSecond = UInt64(d.integer(forKey: ManagedPreferenceKey.bandwidthLimit))
        }
        if d.object(forKey: ManagedPreferenceKey.stripQuarantine) != nil {
            policy.stripQuarantine = d.bool(forKey: ManagedPreferenceKey.stripQuarantine)
        }
        if d.object(forKey: ManagedPreferenceKey.keepNumericOwner) != nil {
            policy.remapOwnerToReceivingUser = !d.bool(forKey: ManagedPreferenceKey.keepNumericOwner)
        }
        if managedMode, network.discoveryMode == .nearby {
            network.discoveryMode = .explicit
        }
    }

    /// Load MDM DLP policy. Enforcement beyond preview is a later release; keys are live for staging.
    static func dlpPolicy() -> DLPPolicy {
        let d = suite
        guard d.object(forKey: DLPManagedKey.enabled) as? Bool == true else {
            return .disabled
        }
        return DLPPolicy(
            enabled: true,
            locked: d.object(forKey: DLPManagedKey.locked) as? Bool ?? false,
            blockedExtensions: d.stringArray(forKey: DLPManagedKey.blockedExtensions) ?? [],
            blockedPathSuffixes: d.stringArray(forKey: DLPManagedKey.blockedPathSuffixes) ?? [],
            maxFileBytes: UInt64(d.integer(forKey: DLPManagedKey.maxFileBytes)),
            blockedNameSubstrings: d.stringArray(forKey: DLPManagedKey.blockedNameSubstrings) ?? [],
            requireAllowlistedPeer: d.object(forKey: DLPManagedKey.requireAllowlistedPeer) as? Bool ?? false,
            blockOutbound: d.object(forKey: DLPManagedKey.blockOutbound) as? Bool ?? false,
            blockInbound: d.object(forKey: DLPManagedKey.blockInbound) as? Bool ?? false,
            policyLabel: d.string(forKey: DLPManagedKey.policyLabel)
        )
    }
}
