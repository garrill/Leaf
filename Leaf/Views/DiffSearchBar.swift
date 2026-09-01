import SwiftUI

/// Stable host for the find-in-diff bar. `DiffView` puts *this* in its `.safeAreaBar` and never
/// anything conditional, so a `DiffView.body` re-render can't rebuild the bar subtree and drop
/// the search field's focus. The show/hide + slide transition live here.
struct DiffSearchBarSlot: View {
    @Bindable var appState: AppState
    var fieldFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            if appState.diffFindBarVisible {
                DiffSearchBar(appState: appState, fieldFocused: fieldFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 19)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.diffFindBarVisible)
    }
}

/// The bar itself: pure SwiftUI so the soft scroll-edge blur composes behind it. Liquid Glass
/// throughout — the field mirrors the commit message box, the ‹ › stepper is one joined glass
/// pill, Done is a circular glass check. The search (scan, dim, rounded highlights, scroll) lives
/// in `DiffScrollContent` / `DiffCodeTextView`; this view only edits `AppState.diffFind*`.
struct DiffSearchBar: View {
    @Bindable var appState: AppState
    var fieldFocused: FocusState<Bool>.Binding

    private var matchLabel: String {
        guard !appState.diffFindQuery.isEmpty else { return "" }
        guard appState.diffFindMatchCount > 0 else { return "No matches" }
        return "\(appState.diffFindCurrentIndex + 1) of \(appState.diffFindMatchCount)"
    }

    var body: some View {
        HStack(spacing: 10) {
            field
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    stepper
                    doneButton
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { fieldFocused.wrappedValue = true }
        .onExitCommand { appState.hideDiffFind() }
    }

    private var field: some View {
        // Every child is always present (visibility toggled with opacity, not `if`) so the
        // TextField's identity never shifts and it keeps focus while typing.
        HStack(spacing: 6) {
            magnifier

            TextField("Find in diff", text: $appState.diffFindQuery)
                .textFieldStyle(.plain)
                .focused(fieldFocused)
                .onSubmit {
                    appState.recordDiffFindRecent()
                    appState.diffFindNext()
                }
                .onKeyPress(.escape) {
                    appState.hideDiffFind()
                    return .handled
                }

            Text(matchLabel)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .opacity(matchLabel.isEmpty ? 0 : 1)

            Button {
                appState.diffFindQuery = ""
                fieldFocused.wrappedValue = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear")
            .opacity(appState.diffFindQuery.isEmpty ? 0 : 1)
            .allowsHitTesting(!appState.diffFindQuery.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    /// Magnifying glass + down chevron → the find-options menu (mirrors Xcode's).
    private var magnifier: some View {
        Menu {
            Toggle("Ignore Case", isOn: $appState.diffFindIgnoreCase)
            Toggle("Wrap Around", isOn: $appState.diffFindWrapAround)

            Divider()

            Picker("Match Mode", selection: $appState.diffFindMode) {
                Text("Contains").tag(DiffFindMode.contains)
                Text("Starts With").tag(DiffFindMode.startsWith)
                Text("Full Word").tag(DiffFindMode.fullWord)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if !appState.diffFindRecents.isEmpty {
                Divider()
                Section("Recent Searches") {
                    ForEach(appState.diffFindRecents, id: \.self) { recent in
                        Button(recent) { appState.diffFindQuery = recent }
                    }
                }
                Divider()
                Button("Clear Recent Searches") { appState.diffFindRecents = [] }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// ‹ | › as a single glass capsule split by a divider.
    private var stepper: some View {
        HStack(spacing: 0) {
            stepButton("chevron.left") { appState.diffFindPrevious() }
            Divider().frame(height: 14)
            stepButton("chevron.right") { appState.diffFindNext() }
        }
        .glassEffect(.regular, in: Capsule())
        .disabled(appState.diffFindMatchCount == 0)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var doneButton: some View {
        Button {
            appState.recordDiffFindRecent()
            appState.hideDiffFind()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help("Done")
    }
}
