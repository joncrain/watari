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
}
