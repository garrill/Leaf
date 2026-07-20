import SwiftUI

struct DiffView: View {
    @Bindable var appState: AppState

    var body: some View {
        Group {
            if let errorMessage = appState.errorMessage {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if appState.selectedFile == nil {
                ContentUnavailableView("No File Selected", systemImage: "doc.text")
            } else if appState.diffText.isEmpty {
                ContentUnavailableView("No Changes To Show", systemImage: "doc.text")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .background(background(for: line))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diffLines: [String] {
        appState.diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return .secondary
        } else if line.hasPrefix("+") {
            return .green
        } else if line.hasPrefix("-") {
            return .red
        } else if line.hasPrefix("@@") {
            return .blue
        }
        return .primary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return .clear
        } else if line.hasPrefix("+") {
            return .green.opacity(0.12)
        } else if line.hasPrefix("-") {
            return .red.opacity(0.12)
        }
        return .clear
    }
}
