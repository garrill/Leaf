import Foundation

/// Boxes a sidebar entry (folder or repo) as an object so `NSOutlineView` can use it as an item
/// identity. Instances are cached by key in `SidebarOutlineCoordinator` so the same repo/folder
/// always maps to the same object across reloads, letting the outline view preserve selection and
/// expansion state.
final class SidebarOutlineItem: NSObject {
    enum Kind: Hashable {
        case folder(UUID)
        case repo(UUID)
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }
}
