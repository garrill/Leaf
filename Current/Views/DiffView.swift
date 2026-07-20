import AppKit
import SwiftUI

private struct DiffLine: Identifiable {
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

    private static let addedTextColor = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.75, green: 1.0, blue: 0.8, alpha: 1)
            : NSColor(red: 0.0, green: 0.35, blue: 0.05, alpha: 1)
    })
    private static let removedTextColor = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.8, blue: 0.8, alpha: 1)
            : NSColor(red: 0.55, green: 0.02, blue: 0.02, alpha: 1)
    })
    private static let addedBackground = Color.green.opacity(0.12)
    private static let removedBackground = Color.red.opacity(0.12)

    var body: some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) {
                if appState.selectedFile != nil {
                    header
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = appState.errorMessage {
            ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if appState.selectedFile == nil {
            ContentUnavailableView("No File Selected", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if appState.diffText.isEmpty {
            ContentUnavailableView("No Changes To Show", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diffLines) { line in
                        row(for: line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    // MARK: - Diff rows

    @ViewBuilder
    private func row(for line: DiffLine) -> some View {
        if line.kind == .hunkHeader {
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
        } else {
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldLineNumber.map(String.init) ?? "")
                    .frame(width: 36, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Text(line.newLineNumber.map(String.init) ?? "")
                    .frame(width: 36, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                Text(line.displayText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(foreground(for: line.kind))
            }
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(background(for: line.kind))
        }
    }

    private func foreground(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Self.addedTextColor
        case .removed: return Self.removedTextColor
        case .meta: return .secondary
        case .context, .hunkHeader: return .primary
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Self.addedBackground
        case .removed: return Self.removedBackground
        case .context, .hunkHeader, .meta: return .clear
        }
    }

    // MARK: - Parsing

    private var diffLines: [DiffLine] {
        Self.parse(appState.diffText)
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
}
