import Foundation

public enum PreviewAction: String, Codable, Sendable, Equatable {
    case unchanged
    case copy
    case update
    case keepBoth
    case skip
}

public enum SkipReason: String, Codable, Sendable, Equatable {
    case denylist
    case specialFile
    case symlinkOutsideSelection
    case icloudNotDownloaded
    case tccDenied
    case unreadable
    case dlp
    case conflict
}

public struct PreviewItem: Codable, Sendable, Equatable {
    public var relativePath: String
    public var action: PreviewAction
    public var skipReason: SkipReason?
    public var source: FileMetadata?
    public var destination: FileMetadata?
    public var permissionExceptions: [PermissionException]

    public init(
        relativePath: String,
        action: PreviewAction,
        skipReason: SkipReason? = nil,
        source: FileMetadata? = nil,
        destination: FileMetadata? = nil,
        permissionExceptions: [PermissionException] = []
    ) {
        self.relativePath = relativePath
        self.action = action
        self.skipReason = skipReason
        self.source = source
        self.destination = destination
        self.permissionExceptions = permissionExceptions
    }
}

public struct PreviewSummary: Codable, Sendable, Equatable {
    public var unchanged: Int
    public var copy: Int
    public var update: Int
    public var keepBoth: Int
    public var skip: Int
    public var permissionExceptionCount: Int
    public var items: [PreviewItem]

    public init(items: [PreviewItem]) {
        self.items = items
        self.unchanged = items.filter { $0.action == .unchanged }.count
        self.copy = items.filter { $0.action == .copy }.count
        self.update = items.filter { $0.action == .update }.count
        self.keepBoth = items.filter { $0.action == .keepBoth }.count
        self.skip = items.filter { $0.action == .skip }.count
        self.permissionExceptionCount = items.reduce(0) { $0 + $1.permissionExceptions.count }
    }
}

public enum PreviewDiff {
    /// Build a preview from source entries and optional destination fingerprints.
    public static func build(
        sources: [FileMetadata],
        destinations: [String: FileMetadata] = [:],
        denylist: Denylist = Denylist(),
        skipped: [(path: String, reason: SkipReason)] = [],
        policy: PermissionPolicy = .default,
        conflict: ConflictPolicy = .default,
        dlp: DLPPolicy = .disabled,
        receiving: ReceivingIdentity
    ) -> PreviewSummary {
        var items: [PreviewItem] = []
        var taken = Set(destinations.keys)
        for source in sources {
            taken.insert(source.relativePath)
        }

        for skip in skipped {
            items.append(
                PreviewItem(relativePath: skip.path, action: .skip, skipReason: skip.reason)
            )
        }

        for source in sources {
            if denylist.blocks(relativePath: source.relativePath) {
                items.append(
                    PreviewItem(
                        relativePath: source.relativePath,
                        action: .skip,
                        skipReason: .denylist,
                        source: source
                    )
                )
                continue
            }

            let dlpVerdict = DLPEngine.evaluateFile(
                relativePath: source.relativePath,
                size: source.size,
                policy: dlp
            )
            if dlpVerdict != .allow {
                items.append(
                    PreviewItem(
                        relativePath: source.relativePath,
                        action: .skip,
                        skipReason: .dlp,
                        source: source
                    )
                )
                continue
            }

            let applied = PermissionPolicyEngine.apply(source, policy: policy, receiving: receiving)

            if let dest = destinations[source.relativePath] {
                if sameContent(source, dest) {
                    items.append(
                        PreviewItem(
                            relativePath: source.relativePath,
                            action: .unchanged,
                            source: source,
                            destination: dest,
                            permissionExceptions: applied.exceptions
                        )
                    )
                } else {
                    switch conflict {
                    case .keepBoth:
                        let renamed = KeepBothPath.allocate(source.relativePath, taken: taken)
                        taken.insert(renamed)
                        var renamedSource = source
                        renamedSource.relativePath = renamed
                        let renamedApplied = PermissionPolicyEngine.apply(
                            renamedSource,
                            policy: policy,
                            receiving: receiving
                        )
                        items.append(
                            PreviewItem(
                                relativePath: renamed,
                                action: .keepBoth,
                                source: renamedSource,
                                destination: dest,
                                permissionExceptions: renamedApplied.exceptions
                            )
                        )
                    case .update:
                        items.append(
                            PreviewItem(
                                relativePath: source.relativePath,
                                action: .update,
                                source: source,
                                destination: dest,
                                permissionExceptions: applied.exceptions
                            )
                        )
                    case .skip:
                        items.append(
                            PreviewItem(
                                relativePath: source.relativePath,
                                action: .skip,
                                skipReason: .conflict,
                                source: source,
                                destination: dest,
                                permissionExceptions: applied.exceptions
                            )
                        )
                    }
                }
            } else {
                items.append(
                    PreviewItem(
                        relativePath: source.relativePath,
                        action: .copy,
                        source: source,
                        permissionExceptions: applied.exceptions
                    )
                )
            }
        }

        items.sort { $0.relativePath < $1.relativePath }
        return PreviewSummary(items: items)
    }

    private static func sameContent(_ a: FileMetadata, _ b: FileMetadata) -> Bool {
        // Same folder on destination → merge (directory entry itself is not a content conflict).
        if a.isDirectory && b.isDirectory {
            return true
        }
        if let fa = a.contentFingerprint, let fb = b.contentFingerprint {
            return fa == fb && a.isDirectory == b.isDirectory && a.isSymlink == b.isSymlink
        }
        return a.size == b.size
            && a.modificationTime == b.modificationTime
            && a.isDirectory == b.isDirectory
            && a.isSymlink == b.isSymlink
            && a.symlinkTarget == b.symlinkTarget
    }
}
