import AppKit
import HighlightSwift
import SwiftUI

struct DiffLine: Identifiable {
    enum Kind {
        case hunkHeader
        case context
        case added
        case removed
        case meta
    }

    let id: Int
    let kind: Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String

    /// The line with its leading +/-/space marker stripped, since that's conveyed by color/gutter instead.
    var displayText: String {
        kind == .hunkHeader || kind == .meta ? text : String(text.dropFirst())
    }
}

struct DiffView: View {
    @Bindable var appState: AppState
    var focusedColumn: FocusState<MainColumn?>.Binding
    @Environment(\.colorScheme) private var colorScheme
    /// Tagged with the diff text it was computed for. Row rendering only trusts it when that tag
    /// still matches `appState.diffText`, so a still-running (or superseded) highlight task can
    /// never paint stale colors onto a newly-selected file's text — the text itself always comes
    /// straight from `diffLines`, computed synchronously, so switching files never waits on
    /// highlighting to show anything.
    @State private var highlightSnapshot: HighlightSnapshot?
    /// Scroll state for the diff pane so the up/down arrow keys can drive it once focus has
    /// moved here (right arrow from the files list) — synced from real scroll events via
    /// `onScrollGeometryChange` and driven programmatically via `scrollPosition`.
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollOffsetY: CGFloat = 0
    private static let arrowScrollStep: CGFloat = 40

    static let addedTextNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.75, green: 1.0, blue: 0.8, alpha: 1)
            : NSColor(red: 0.0, green: 0.35, blue: 0.05, alpha: 1)
    }
    static let removedTextNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.8, blue: 0.8, alpha: 1)
            : NSColor(red: 0.55, green: 0.02, blue: 0.02, alpha: 1)
    }
    private static let addedTextColor = Color(addedTextNSColor)
    private static let removedTextColor = Color(removedTextNSColor)
    static let addedBackgroundNSColor = NSColor.systemGreen.withAlphaComponent(0.12)
    static let removedBackgroundNSColor = NSColor.systemRed.withAlphaComponent(0.12)
    static let strongAddedBackgroundNSColor = NSColor.systemGreen.withAlphaComponent(0.4)
    static let strongRemovedBackgroundNSColor = NSColor.systemRed.withAlphaComponent(0.4)
    static let hunkHeaderBackgroundNSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08)

    /// Code text always uses the default label color — added/removed lines are conveyed by the
    /// row/word background tinting, not by tinting the text itself, so syntax highlighting colors
    /// stay legible and consistent regardless of a line's diff kind.
    static func foregroundNSColor(for kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .meta: return .secondaryLabelColor
        case .added, .removed, .context, .hunkHeader: return .labelColor
        }
    }

    static func backgroundNSColor(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: return addedBackgroundNSColor
        case .removed: return removedBackgroundNSColor
        case .context, .hunkHeader, .meta: return nil
        }
    }

    /// The stronger "word diff" highlight for the sub-range of an added/removed line that
    /// actually changed, layered on top of the line's own faint full-row background.
    static func strongBackgroundNSColor(for kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: return strongAddedBackgroundNSColor
        case .removed: return strongRemovedBackgroundNSColor
        case .context, .hunkHeader, .meta: return nil
        }
    }

    var body: some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) {
                if appState.selectedFile != nil {
                    header
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .focusable()
            .focusEffectDisabled()
            .focused(focusedColumn, equals: .diff)
            .onKeyPress(.leftArrow) {
                focusedColumn.wrappedValue = .files
                return .handled
            }
            .onKeyPress(.upArrow) {
                scrollBy(-Self.arrowScrollStep)
                return .handled
            }
            .onKeyPress(.downArrow) {
                scrollBy(Self.arrowScrollStep)
                return .handled
            }
    }

    private func scrollBy(_ delta: CGFloat) {
        let newY = max(0, scrollOffsetY + delta)
        scrollPosition.scrollTo(point: CGPoint(x: 0, y: newY))
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = appState.errorMessage {
            ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if appState.selectedFile == nil {
            if appState.selectedSource != nil && appState.changedFiles.isEmpty {
                // A selected commit/source with no changed files at all (e.g. an empty commit) —
                // there's nothing wrong here, so no "No File Selected" message either.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else if appState.selectedFile?.isLikelyImage == true {
            ImageDiffView(appState: appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if appState.diffText.hasPrefix("Binary files ") {
            ContentUnavailableView(
                "Binary File Changed",
                systemImage: "doc.badge.gearshape",
                description: Text(fileName)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if appState.diffText.isEmpty {
            ContentUnavailableView("No Changes To Show", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                DiffCodeScrollView(lines: diffLines, highlightSnapshot: highlightSnapshot, diffText: appState.diffText)
                    .frame(maxWidth: .infinity)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                scrollOffsetY = newValue
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: HighlightRequest(path: appState.selectedFile?.path, diffText: appState.diffText, isDark: colorScheme == .dark)) {
                await refreshHighlighting()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            pathAndFileName
                .font(.system(.body))
                .lineLimit(1)
                .truncationMode(.head)
                .truncationTooltip(appState.selectedFile?.path ?? "")

            Spacer(minLength: 8)

            if addedCount > 0 {
                Text("+\(addedCount)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Self.addedTextColor)
            }
            if removedCount > 0 {
                Text("-\(removedCount)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Self.removedTextColor)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: MainWindowView.columnHeaderHeight)
    }

    /// Directory in secondary/grey, file name in primary/black, on one line.
    private var pathAndFileName: Text {
        let name = Text(fileName).foregroundColor(.primary)
        guard !directoryPath.isEmpty else { return name }
        let directory = Text(directoryPath + "/").foregroundColor(.secondary)
        return Text("\(directory)\(name)")
    }

    private var fileName: String {
        (appState.selectedFile?.path as NSString?)?.lastPathComponent ?? ""
    }

    private var directoryPath: String {
        guard let path = appState.selectedFile?.path else { return "" }
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? "" : directory
    }

    // MARK: - Parsing

    private var diffLines: [DiffLine] {
        if appState.selectedFile?.status == .conflicted {
            return Self.parsePlainText(appState.diffText)
        }
        return Self.parse(appState.diffText)
    }

    private var addedCount: Int {
        diffLines.count { $0.kind == .added }
    }

    private var removedCount: Int {
        diffLines.count { $0.kind == .removed }
    }

    private static let hunkHeaderRegex = try? NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)

    /// Parses unified diff text into per-line data with old/new line numbers, skipping the
    /// `diff --git` / `index` / `---` / `+++` preamble before the first hunk.
    private static func parse(_ diffText: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var sawHunk = false
        var nextID = 0

        for substring in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(substring)

            if line.hasPrefix("@@") {
                sawHunk = true
                if let regex = hunkHeaderRegex,
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let oldRange = Range(match.range(at: 1), in: line),
                   let newRange = Range(match.range(at: 2), in: line) {
                    oldLine = Int(line[oldRange]) ?? 0
                    newLine = Int(line[newRange]) ?? 0
                }
                result.append(DiffLine(id: nextID, kind: .hunkHeader, oldLineNumber: nil, newLineNumber: nil, text: line))
                nextID += 1
                continue
            }

            guard sawHunk else { continue }

            if line.isEmpty {
                continue
            } else if line.hasPrefix("\\") {
                result.append(DiffLine(id: nextID, kind: .meta, oldLineNumber: nil, newLineNumber: nil, text: line))
            } else if line.hasPrefix("+") {
                result.append(DiffLine(id: nextID, kind: .added, oldLineNumber: nil, newLineNumber: newLine, text: line))
                newLine += 1
            } else if line.hasPrefix("-") {
                result.append(DiffLine(id: nextID, kind: .removed, oldLineNumber: oldLine, newLineNumber: nil, text: line))
                oldLine += 1
            } else {
                result.append(DiffLine(id: nextID, kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: line))
                oldLine += 1
                newLine += 1
            }
            nextID += 1
        }

        return result
    }

    /// Renders raw file text (a conflicted file's working-tree contents, markers and all) as
    /// plain context lines — unlike `parse`, this doesn't require `@@` hunk headers, since a
    /// conflicted file's content is not unified-diff output at all.
    private static func parsePlainText(_ text: String) -> [DiffLine] {
        let substrings = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [DiffLine] = []
        var lineNumber = 1
        for (index, substring) in substrings.enumerated() {
            if substring.isEmpty && index == substrings.count - 1 { continue }
            // Leading space mirrors unified-diff's context-line marker, since `displayText`
            // unconditionally drops the first character for non-header/meta lines.
            result.append(DiffLine(id: index, kind: .context, oldLineNumber: nil, newLineNumber: lineNumber, text: " " + String(substring)))
            lineNumber += 1
        }
        return result
    }

    // MARK: - Syntax highlighting

    /// Highlights the diff by reconstructing each hunk's old side (context + removed lines) and
    /// new side (context + added lines) as one text block per side, in order, and sending each
    /// block through HighlightSwift as a single call. This needs no extra git blob fetches — the
    /// hunk already carries both sides' text — and gives hljs enough surrounding code to tokenize
    /// multi-line constructs (strings, comments) far better than highlighting line-by-line, at the
    /// cost of occasionally mis-tokenizing right at a hunk boundary.
    ///
    /// Text renders immediately from `diffLines` regardless of how long this takes — this only
    /// ever adds color on top, later, once (and if) it finishes.
    /// Above this many lines, skip highlighting entirely — a huge diff means many concurrent
    /// hljs calls competing with the main thread for CPU, which is felt as jank even though the
    /// calls themselves are async, and syntax color is the least useful on a diff this size anyway.
    private static let maxHighlightedLineCount = 2000

    private func refreshHighlighting() async {
        let targetDiffText = appState.diffText
        let lines = Self.parse(targetDiffText)
        guard !lines.isEmpty, lines.count <= Self.maxHighlightedLineCount else { return }

        let language = appState.selectedFile.flatMap { CodeHighlighter.language(forPath: $0.path) }
        let isDark = colorScheme == .dark

        var oldSideRun: [DiffLine] = []
        var newSideRun: [DiffLine] = []
        var runs: [[DiffLine]] = []

        func flush() {
            if !oldSideRun.isEmpty { runs.append(oldSideRun); oldSideRun = [] }
            if !newSideRun.isEmpty { runs.append(newSideRun); newSideRun = [] }
        }

        for line in lines {
            switch line.kind {
            case .hunkHeader, .meta:
                flush()
            case .context:
                oldSideRun.append(line)
                newSideRun.append(line)
            case .removed:
                oldSideRun.append(line)
            case .added:
                newSideRun.append(line)
            }
        }
        flush()

        var result: [Int: AttributedString] = [:]

        // Runs are independent hunk-side blocks, so highlight them all concurrently rather than
        // waiting on one JS round-trip before starting the next.
        await withTaskGroup(of: (run: [DiffLine], attributed: AttributedString?).self) { group in
            for run in runs {
                // Joined here, on the main actor, since `DiffLine.displayText` is a main-actor
                // isolated computed property (this file's default isolation) and can't be
                // referenced via key path from inside the concurrently-executing child task below.
                let text = run.map(\.displayText).joined(separator: "\n")
                group.addTask {
                    let attributed = await CodeHighlighter.attributedText(text, language: language, isDark: isDark)
                    return (run, attributed)
                }
            }
            for await (run, attributed) in group {
                guard let attributed else { continue }
                let pieces = Self.splitLines(attributed)
                guard pieces.count == run.count else { continue }
                for (line, piece) in zip(run, pieces) {
                    result[line.id] = piece
                }
            }
        }

        if !Task.isCancelled {
            highlightSnapshot = HighlightSnapshot(diffText: targetDiffText, lines: result)
        }
    }

    /// Splits a syntax-highlighted block back into its per-line pieces on "\n", preserving each
    /// line's token colors, since HighlightSwift only hands back one AttributedString per call.
    private static func splitLines(_ attributed: AttributedString) -> [AttributedString] {
        var lines: [AttributedString] = []
        var start = attributed.startIndex
        var index = attributed.startIndex
        while index < attributed.endIndex {
            if attributed.characters[index] == "\n" {
                lines.append(AttributedString(attributed[start..<index]))
                start = attributed.index(afterCharacter: index)
            }
            index = attributed.index(afterCharacter: index)
        }
        lines.append(AttributedString(attributed[start..<attributed.endIndex]))
        return lines
    }
}

struct HighlightSnapshot {
    let diffText: String
    let lines: [Int: AttributedString]
}

private struct HighlightRequest: Equatable {
    let path: String?
    let diffText: String
    let isDark: Bool
}
