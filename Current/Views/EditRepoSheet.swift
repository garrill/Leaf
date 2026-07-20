import AppKit
import SwiftUI

struct EditRepoSheet: View {
    let repo: SidebarRepo
    let sidebarStore: SidebarStore

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var iconPath: String?

    init(repo: SidebarRepo, sidebarStore: SidebarStore) {
        self.repo = repo
        self.sidebarStore = sidebarStore
        _name = State(initialValue: repo.displayName)
        _iconPath = State(initialValue: repo.iconPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Repository")
                .font(.headline)

            Form {
                TextField("Display Name", text: $name)

                HStack {
                    iconPreview
                        .frame(width: 32, height: 32)
                    Button("Choose Icon…") { pickIcon() }
                    if iconPath != nil {
                        Button("Reset to Default") { iconPath = nil }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let override = (trimmed.isEmpty || trimmed == repo.url.lastPathComponent) ? nil : trimmed
                    sidebarStore.updateRepo(id: repo.id, displayName: override, iconPath: iconPath)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let iconPath, let nsImage = NSImage(contentsOfFile: iconPath) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "folder.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }

    private func pickIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = repo.url
        panel.prompt = "Choose Icon"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        iconPath = url.path
    }
}
