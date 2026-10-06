import Foundation

struct BookmarkEntry: Identifiable, Equatable, Hashable {
    var id: String
    var displayName: String
    var path: String
    var bookmarkData: Data
}
