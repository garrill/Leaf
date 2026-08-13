import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Central place for the handful of `UserDefaults` keys/defaults `SettingsView` exposes, so the
/// diff pane (`DiffView`/`DiffCodeTextView`) and the "Open in External Editor" action
/// (`ChangedFilesView`) read the exact same keys/fallbacks this view writes.
enum LeafSettings {
    static let diffFontSizeKey = "diffFontSize"
    static let externalEditorPathKey = "externalEditorPath"

    static let defaultDiffFontSize = Double(NSFont.systemFontSize)
    static let diffFontSizeRange: ClosedRange<Double> = 10...20

    /// Opens `url` with the user's configured external editor if set, falling back to its normal
    /// macOS default application otherwise. Shared by `ChangedFilesView`'s per-file "Open in
    /// Default Program" and the Repository menu's "Open in <App>" for the repo root — both need
    /// the exact same fallback behavior.
    static func open(_ url: URL) {
        let path = UserDefaults.standard.string(forKey: externalEditorPathKey) ?? ""
        guard !path.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }
}

struct SettingsView: View {
    @AppStorage(LeafSettings.diffFontSizeKey) private var diffFontSize = LeafSettings.defaultDiffFontSize
    @AppStorage(LeafSettings.externalEditorPathKey) private var externalEditorPath = ""

    var body: some View {
        Form {
            Section("Diff") {
                HStack {
                    Slider(value: $diffFontSize, in: LeafSettings.diffFontSizeRange, step: 1) {
                        Text("Font Size")
                    }
                    Text("\(Int(diffFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("External Editor") {
                HStack {
                    Text(externalEditorName)
                        .foregroundStyle(externalEditorPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { chooseExternalEditor() }
                    if !externalEditorPath.isEmpty {
                        Button("Use System Default") { externalEditorPath = "" }
                    }
                }
                Text("\u{201C}Open in Default Program\u{201D} uses this editor when set, or the file's normal macOS default otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Leaf runs entirely on your Mac. It talks only to the git you already have installed and to the remotes you configure — nothing about your repositories, code, or usage is collected or sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var externalEditorName: String {
        guard !externalEditorPath.isEmpty else { return "System Default" }
        return FileManager.default.displayName(atPath: externalEditorPath)
    }

    private func chooseExternalEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        externalEditorPath = url.path
    }
}
