import AppKit
import SwiftUI

/// Presents a failure as an `NSAlert` with a "Copy Full Log" button. This is AppKit rather than
/// SwiftUI's `.alert` because every `.alert` button dismisses it, so copying the log would also
/// lose the alert's message and any offered fixes.
enum GitErrorAlert {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    /// Shown as a sheet on the main window. `actions` come first (the first is the default
    /// button), then Cancel, or OK if there are no actions.
    static func present(title: String, message: String, log: String?, actions: [Action] = [], onDismiss: @escaping () -> Void = {}) {
        // A button's target is weak, so the completion handlers below keep this alive.
        let (alert, copyTarget) = makeAlert(title: title, message: message, log: log, actionTitles: actions.map(\.title))

        let finish = { (response: NSApplication.ModalResponse) in
            withExtendedLifetime(copyTarget) {}
            onDismiss()
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if actions.indices.contains(index) {
                actions[index].handler()
            }
        }

        // `NSApp.mainWindow` is nil while the app is inactive, which is a likely moment for a slow
        // push to fail, so the window is found by its controller instead.
        if let window = NSApp.windows.first(where: { $0.windowController is MainWindowController }) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    fileprivate static func makeAlert(title: String, message: String, log: String?, actionTitles: [String]) -> (NSAlert, CopyLogTarget?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message

        for actionTitle in actionTitles {
            alert.addButton(withTitle: actionTitle)
        }
        alert.addButton(withTitle: actionTitles.isEmpty ? "OK" : "Cancel")

        let copyTarget = log.map(CopyLogTarget.init(log:))
        if let copyTarget {
            let copyButton = alert.addButton(withTitle: "Copy Full Log")
            copyButton.target = copyTarget
            copyButton.action = #selector(CopyLogTarget.copyLog(_:))
        }
        return (alert, copyTarget)
    }

    fileprivate final class CopyLogTarget: NSObject {
        let log: String

        init(log: String) {
            self.log = log
        }

        @objc func copyLog(_ sender: NSButton) {
            GitErrorLog.copy(log)
            sender.title = "Copied"
        }
    }
}

enum GitErrorLog {
    static func copy(_ log: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log, forType: .string)
    }
}

/// "Copy Full Log", confirming once clicked.
struct CopyLogButton: View {
    let log: String
    @State private var copiedLog: String?

    var body: some View {
        Button(copiedLog == log ? "Copied" : "Copy Full Log") {
            GitErrorLog.copy(log)
            copiedLog = log
        }
    }
}

/// A failure filling the diff pane.
struct GitErrorPaneView: View {
    let rawMessage: String

    var body: some View {
        let report = GitErrorReport(rawOutput: rawMessage)
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(report.summary)
        } actions: {
            if report.hasFurtherDetail {
                CopyLogButton(log: report.fullLog)
            }
        }
    }
}

/// An inline failure inside a sheet: the summary, plus the log button when the log has more to say.
struct GitErrorMessageView: View {
    let rawMessage: String

    var body: some View {
        let report = GitErrorReport(rawOutput: rawMessage)
        VStack(alignment: .leading, spacing: 4) {
            Text(report.summary)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            if report.hasFurtherDetail {
                CopyLogButton(log: report.fullLog)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

#if DEBUG
/// Sample stderr in the shapes git really emits, run through the real parser by the previews.
enum GitErrorPreviewSample {
    private static let pushProgress = (1...79).map { "Counting objects: \($0 * 100 / 79)% (\($0)/79)" }.joined(separator: "\r")
        + "\rCounting objects: 100% (79/79), done.\nDelta compression using up to 10 threads\n"
        + (1...49).map { "Writing objects: \($0 * 100 / 49)% (\($0)/49)" }.joined(separator: "\r")
        + "\rWriting objects: 100% (49/49), 9.28 KiB | 9.28 MiB/s, done.\nTotal 49 (delta 30), reused 26 (delta 9), pack-reused 0 (from 0)\n"

    static let remoteFailure = pushProgress + """
    remote: fatal error in commit_refs
    To github.com:acme/site.git
     ! [remote rejected]     staging -> staging (failure)
    error: failed to push some refs to 'github.com:acme/site.git'
    """

    static let protectedBranch = pushProgress + """
    remote: error: GH006: Protected branch update failed for refs/heads/main.
    remote: error: Changes must be made through a pull request.
    To github.com:acme/site.git
     ! [remote rejected] main -> main (protected branch hook declined)
    error: failed to push some refs to 'github.com:acme/site.git'
    """

    static let nonFastForward = """
    To github.com:acme/site.git
     ! [rejected]        main -> main (fetch first)
    error: failed to push some refs to 'github.com:acme/site.git'
    hint: Updates were rejected because the remote contains work that you do not have locally.
    """

    static let blockedPull = """
    From github.com:acme/site
       ce0c1c0..d6f0788  main       -> origin/main
    error: Your local changes to the following files would be overwritten by merge:
    \tSources/App.swift
    \tREADME.md
    Please commit your changes or stash them before you merge.
    Aborting
    Updating ce0c1c0..d6f0788
    """

    static let cloneFailure = "Cloning into 'site'...\nremote: Repository not found.\nfatal: repository 'https://github.com/acme/site.git/' not found"
}

/// The real `NSAlert`'s content, lifted out of its window so a preview can draw it. The fix buttons
/// are the same titles `ChangedFilesView` would offer, but do nothing here. "Copy Full Log" works.
struct GitFailureAlertPreview: NSViewRepresentable {
    private let alert: NSAlert
    private let copyTarget: AnyObject?
    let size: CGSize

    init(_ rawOutput: String, operation: GitFailureAlert.Operation) {
        let failure = AppState.parseGitFailure(rawOutput, operation: operation)
        let actionTitles = failure.blockingTrackedPaths.map { "Stash \($0)" }
            + (failure.offerPullThenPush ? ["Pull from Origin"] : [])
        (alert, copyTarget) = GitErrorAlert.makeAlert(
            title: failure.title,
            message: failure.displayMessage,
            log: failure.log,
            actionTitles: actionTitles
        )
        alert.layout()
        size = alert.window.contentView?.frame.size ?? .zero
    }

    func makeNSView(context: Context) -> NSView {
        let content = alert.window.contentView ?? NSView()
        // Leaving the window resizes the content view, which would otherwise shift its subviews.
        content.autoresizesSubviews = false
        alert.window.contentView = NSView()
        return content
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { size }
}

struct GitErrorPreviewGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                GitErrorMessageView(rawMessage: sample)
                Divider()
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var samples: [String] {
        [GitErrorPreviewSample.cloneFailure, "fatal: a branch named 'staging' already exists", GitErrorPreviewSample.remoteFailure]
    }
}

#Preview("Alert: remote failure") {
    GitFailureAlertPreview(GitErrorPreviewSample.remoteFailure, operation: .push)
}

#Preview("Alert: protected branch") {
    GitFailureAlertPreview(GitErrorPreviewSample.protectedBranch, operation: .push)
}

#Preview("Alert: push behind remote") {
    GitFailureAlertPreview(GitErrorPreviewSample.nonFastForward, operation: .push)
}

#Preview("Alert: pull blocked") {
    GitFailureAlertPreview(GitErrorPreviewSample.blockedPull, operation: .pull)
}

#Preview("Sheet messages") {
    GitErrorPreviewGallery()
}

#Preview("Diff pane") {
    GitErrorPaneView(rawMessage: GitErrorPreviewSample.remoteFailure)
        .frame(width: 600, height: 400)
}
#endif
