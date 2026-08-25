import SwiftUI
import AppKit

struct CloneRepoSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var urlString = ""
    @State private var destinationParent = FileManager.default.homeDirectoryForCurrentUser
    @FocusState private var isURLFieldFocused: Bool

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var destinationPreviewPath: String {
        guard !trimmedURL.isEmpty else { return "" }
        return destinationParent.appendingPathComponent(GitRepository.repoName(fromURLString: trimmedURL)).path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clone Repository")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository URL")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("https://github.com/user/repo.git", text: $urlString)
                        .textFieldStyle(.plain)
                        .disableAutocorrection(true)
                        .focused($isURLFieldFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .disabled(appState.isCloning)
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
                            .buttonStyle(.glass)
                            .disabled(appState.isCloning)
                    }
                    if !destinationPreviewPath.isEmpty {
                        Text(destinationPreviewPath)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if appState.isCloning {
                    VStack(alignment: .leading, spacing: 6) {
                        Divider()
                        if let fraction = appState.cloneProgressFraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                        Text(appState.cloneProgressText ?? "Cloning…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                if let error = appState.cloneErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(appState.isCloning)
                Button {
                    startClone()
                } label: {
                    Text(appState.isCloning ? "Cloning…" : "Clone")
                        .frame(minWidth: 40)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(trimmedURL.isEmpty || appState.isCloning)
            }
            .padding(20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.25), value: appState.isCloning)
        .animation(.easeInOut(duration: 0.2), value: appState.cloneErrorMessage)
        .onAppear {
            appState.cloneErrorMessage = nil
            isURLFieldFocused = true
        }
    }

    private func startClone() {
        appState.cloneRepo(urlString: urlString, destinationParent: destinationParent) { success in
            if success { isPresented = false }
        }
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
