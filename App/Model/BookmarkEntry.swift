import Foundation

enum FolderAccessKind: String, Equatable, Hashable, Sendable {
    /// Durable user-granted security-scoped bookmark (Add folder… / open panel).
    case securityScoped
    /// Standard home folders covered by home-relative temporary-exception entitlements.
    case homeRelativeException
}

struct BookmarkEntry: Identifiable, Equatable, Hashable {
    var id: String
    var displayName: String
    var path: String
    var bookmarkData: Data
    var access: FolderAccessKind

    init(
        id: String,
        displayName: String,
        path: String,
        bookmarkData: Data,
        access: FolderAccessKind = .securityScoped
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bookmarkData = bookmarkData
        self.access = access
    }
}
