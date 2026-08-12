import Foundation

enum MainColumn: Int, CaseIterable {
    case repos, branches, files, diff
}

enum ColumnLayout {
    /// Shared height for the top bar of the branch, files, and diff columns, so they align.
    static let headerHeight: CGFloat = 37
}
