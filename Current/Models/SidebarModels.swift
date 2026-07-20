import CoreTransferable
import Foundation
import UniformTypeIdentifiers

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

enum SidebarRow: Identifiable, Hashable {
    case folder(SidebarFolder)
    case repo(SidebarRepo, indented: Bool)

    var id: String {
        switch self {
        case .folder(let folder): "folder-\(folder.id)"
        case .repo(let repo, _): "repo-\(repo.id)"
        }
    }
}

enum SidebarDragPayload: Codable, Transferable, Hashable {
    case repo(UUID)
    case folder(UUID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
