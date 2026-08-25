import SwiftUI

struct NewBranchSheet: View {
    @Bindable var appState: AppState
    @Binding var isPresented: Bool

    @State private var name = ""
    @FocusState private var isNameFieldFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Branch")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("From \"\(appState.selectedBranch?.name ?? "current branch")\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Branch name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .focused($isNameFieldFocused)
                    .onSubmit(createBranch)
            }

            if let error = appState.newBranchErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createBranch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            appState.newBranchErrorMessage = nil
            isNameFieldFocused = true
        }
    }

    private func createBranch() {
        guard !trimmedName.isEmpty else { return }
        appState.createBranch(named: trimmedName) { success in
            if success { isPresented = false }
        }
    }
}

#Preview {
    NewBranchSheet(appState: AppState(), isPresented: .constant(true))
}
