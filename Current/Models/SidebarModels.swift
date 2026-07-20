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
