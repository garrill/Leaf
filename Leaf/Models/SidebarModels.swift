import Foundation

struct SidebarRepo: Identifiable, Codable, Hashable {
    let id: UUID
    var path: String
    var displayNameOverride: String?
    var iconPath: String?
    var folderID: UUID?
    var sortIndex: Int

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { displayNameOverride ?? url.lastPathComponent }
}

struct SidebarFolder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var isExpanded: Bool = true
}

enum TopLevelEntry: Codable, Hashable {
    case folder(UUID)
    case repo(UUID)
}

/// The payload dragged when reordering the sidebar via the outline view's native drag-and-drop.
/// Only meaningful within this app/process (carried on the pasteboard as JSON, never exported).
struct SidebarDragItem: Codable, Hashable {
    enum Kind: Codable, Hashable {
        case repo
        case folder
    }

    var kind: Kind
    var id: UUID
}

/// Where a dragged sidebar item should land.
enum SidebarDropTarget: Equatable {
    /// Insert as a top-level entry, before `before` (nil = append at the end).
    case topLevel(before: TopLevelEntry?)
    /// Append into the given folder (used when dropping directly on a folder's header).
    case folderAppend(UUID)
    /// Insert as a child of `folderID`, before `before` (nil = append at the end of that folder).
    case folderChild(folderID: UUID, before: UUID?)
}
