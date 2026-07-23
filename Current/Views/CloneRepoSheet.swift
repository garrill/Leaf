import SwiftUI
import AppKit

struct CloneRepoSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var urlString = ""
    @State private var destinationParent = FileManager.default.homeDirectoryForCurrentUser

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var destinationPreviewPath: String {
        guard !trimmedURL.isEmpty else { return "" }
        return destinationParent.appendingPathComponent(GitRepository.repoName(fromURLString: trimmedURL)).path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Repository")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Repository URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("https://github.com/user/repo.git", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Destination")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(destinationParent.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseDestination() }
                }
                if !destinationPreviewPath.isEmpty {
                    Text(destinationPreviewPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let error = appState.cloneErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(appState.isCloning)
                Button {
                    appState.cloneRepo(urlString: urlString, destinationParent: destinationParent) { success in
                        if success { isPresented = false }
                    }
                } label: {
                    if appState.isCloning {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 40)
                    } else {
                        Text("Clone")
                            .frame(width: 40)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedURL.isEmpty || appState.isCloning)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { appState.cloneErrorMessage = nil }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = destinationParent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationParent = url
    }
}
