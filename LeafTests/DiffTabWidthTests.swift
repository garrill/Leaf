import Testing
@testable import Leaf

@MainActor
struct DiffTabWidthTests {
    private func line(tabs: Int, content: String = "x", kind: DiffLine.Kind = .context) -> DiffLine {
        DiffLine(id: 0, kind: kind, oldLineNumber: nil, newLineNumber: nil, text: " " + String(repeating: "\t", count: tabs) + content)
    }

    @Test func shallowUsesFourColumns() {
        #expect(DiffCodeScrollView.tabColumns(for: []) == 4)
        #expect(DiffCodeScrollView.tabColumns(for: (0...4).map { line(tabs: $0) }) == 4)
    }

    @Test func deepUsesTwoColumnsFromTenPercent() {
        let shallow = Array(repeating: line(tabs: 1), count: 9)
        #expect(DiffCodeScrollView.tabColumns(for: shallow + [line(tabs: 5)]) == 2)
        #expect(DiffCodeScrollView.tabColumns(for: shallow + [line(tabs: 1), line(tabs: 12)]) == 4)
    }

    @Test func ignoresUnindentedBlankAndMetaLines() {
        let unindented = Array(repeating: line(tabs: 0), count: 100)
        #expect(DiffCodeScrollView.tabColumns(for: unindented + [line(tabs: 5)]) == 2)
        #expect(DiffCodeScrollView.tabColumns(for: [line(tabs: 8, content: " \r"), line(tabs: 8, kind: .meta)]) == 4)
    }
}
