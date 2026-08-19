import Combine
import Sparkle

/// Owns the app's single `SPUStandardUpdaterController`. `AppDelegate` touches `shared` once at
/// launch to force its creation (and with it `startingUpdater: true`); `LeafApp`'s "Check for
/// Updates…" command reaches the same instance through this holder since SwiftUI's `.commands`
/// are declared independently of `AppDelegate`.
enum UpdaterHolder {
    static let shared = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

/// Mirrors `SPUUpdater.canCheckForUpdates` into a `@Published` property so the "Check for
/// Updates…" menu item can disable itself while a check/update is already in progress — Sparkle's
/// own recommended pattern for SwiftUI, since the updater itself isn't `ObservableObject`.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
