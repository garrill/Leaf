import SwiftUI

struct NewTagSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var name = ""
    @FocusState private var isNameFieldFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tag Commit")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("At \"\(appState.newTagTargetCommit?.summary ?? "commit")\" (\(appState.newTagTargetCommit?.shortSha ?? ""))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                TextField("Tag name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .focused($isNameFieldFocused)
                    .onSubmit(createTag)
            }

            if let error = appState.newTagErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createTag() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || appState.newTagTargetCommit == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            appState.newTagErrorMessage = nil
            isNameFieldFocused = true
        }
    }

    private func createTag() {
        guard !trimmedName.isEmpty, let sha = appState.newTagTargetCommit?.sha else { return }
        appState.createTag(named: trimmedName, at: sha) { success in
            if success { isPresented = false }
        }
    }
}

private func previewAppState() -> AppState {
    let appState = AppState()
    appState.newTagTargetCommit = GitCommit(
        sha: "a1b2c3d4e5f6",
        shortSha: "a1b2c3d",
        summary: "Feature: add tag support",
        date: .now,
        author: "Jonny"
    )
    return appState
}

#Preview {
    NewTagSheet(appState: previewAppState(), isPresented: .constant(true))
}
