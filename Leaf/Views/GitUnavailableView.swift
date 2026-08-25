import SwiftUI

/// Shown instead of the normal 4-column interface when `GitRepository.isGitAvailable()` fails at
/// launch — most commonly a Mac with neither Xcode nor the standalone Command Line Tools
/// installed, where `/usr/bin/git` exists as a stub but doesn't actually run git.
struct GitUnavailableView: View {
    /// Re-checks availability and, if it now succeeds, swaps in the real interface. Returns
    /// whether it succeeded so this view can show "still not found" feedback if not.
    var onRetry: () -> Bool

    private enum InstallStatus: Equatable {
        case idle
        case launching
        case launched
        case failed(String)
    }

    @State private var showsStillMissing = false
    @State private var installStatus: InstallStatus = .idle

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("Git Not Found")
                .font(.title2.weight(.semibold))

            Text("Leaf needs the git command-line tools, which aren't installed on this Mac. Install Xcode's Command Line Tools, then check again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            statusText

            HStack(spacing: 12) {
                Button {
                    installCommandLineTools()
                } label: {
                    Text("Install Command Line Tools")
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                }
                .buttonBorderShape(.capsule)

                Button {
                    installStatus = .idle
                    showsStillMissing = !onRetry()
                } label: {
                    Text("Check Again")
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                }
                .buttonBorderShape(.capsule)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var statusText: some View {
        switch installStatus {
        case .idle:
            if showsStillMissing {
                Text("Still not found — make sure the install finished, then try again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .launching:
            Text("Opening the installer…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .launched:
            Text("Installer opened in a separate window — finish the install, then click Check Again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func installCommandLineTools() {
        showsStillMissing = false
        installStatus = .launching
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            process.arguments = ["--install"]
            let stderr = Pipe()
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    installStatus = .failed("Couldn't launch the installer: \(error.localizedDescription)")
                }
                return
            }

            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let errorOutput = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            await MainActor.run {
                if process.terminationStatus == 0 {
                    installStatus = .launched
                } else if errorOutput.contains("already installed") {
                    installStatus = .failed("Command Line Tools are already installed — try Check Again, or run Software Update if git still isn't found.")
                } else {
                    installStatus = .failed(errorOutput.isEmpty ? "Couldn't start the installer." : errorOutput)
                }
            }
        }
    }
}

#Preview {
    GitUnavailableView(onRetry: { false })
}
