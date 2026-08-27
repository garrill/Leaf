# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

`Leaf`: native SwiftUI macOS git client, 4-column layout (repos (sidebar) → branches/history → changed files → diff). Currently in beta.

## Build, run, test

Plain Xcode project (`Leaf.xcodeproj`), scheme `Leaf`. No `Package.swift`, but it does resolve two SPM dependencies (`HighlightSwift`, `Sparkle`) via Xcode's own package resolution.

```sh
xcodebuild -project Leaf.xcodeproj -scheme Leaf -configuration Debug build
xcodebuild -project Leaf.xcodeproj -scheme Leaf test
open /path/to/DerivedData/.../Build/Products/Debug/Leaf.app
```

- Quit any running instance before relaunching (`osascript -e 'tell application "Leaf" to quit'`) — xcodebuild won't overwrite a running bundle.
- Don't try to screenshot/screen-record the app (no permission in this terminal) — build, launch, let the user verify visually.
- `LeafUITests` need `-uiTestReset` (handled in `AppDelegate.resetStateIfRequestedForUITesting()`) to wipe `UserDefaults` first so each test starts from a repo-less sidebar.
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) deliberately — app shells out inside arbitrary repo folders on disk.
- `.swift` files under `Leaf/` are picked up automatically (file-system-synchronized groups) — never need adding to `project.pbxproj`.

## Architecture gotchas

- **Git backend shells out to `/usr/bin/git`**, not libgit2/SwiftGit2 (no SPM package reliably links for macOS arm64).
- **AppState is the single source of truth.** `selectSource`/`selectFile` are assignment-only; the actual changed-files/diff git work happens in `AppState.loadChangedFilesForCurrentSelection`/`loadDiffForCurrentSelection`, triggered by `ChangedFilesView`/`DiffView`'s own `.task(id:)`, debounced ~180ms. Callers needing to see their own change immediately (`discardChanges`/`ignoreFiles`/`markResolved`) pass `immediate: true` to skip the debounce.
- **Liquid Glass column header blur** requires `.safeAreaBar(edge: .top)` (not `.safeAreaInset`) paired with `.scrollEdgeEffectStyle(.soft, for: .top)`, and only works over a real SwiftUI `ScrollView`/`List` — never over an `NSScrollView` wrapped in `NSViewRepresentable`. The bar also needs genuine non-empty content.
- **The window is entirely AppKit-owned, not a SwiftUI `WindowGroup`.** `LeafApp.swift` declares only a `Settings` scene; `AppDelegate` builds `MainWindowController`/`NSWindow` directly, hosting `MainSplitViewController`. Needed for `NSTrackingSeparatorToolbarItem` (pinning a toolbar item to an interior column divider — `NavigationSplitView` can't do this). `window.setContentSize(...)`/`.center()` must be re-applied *after* both `contentViewController` and `toolbar` are assigned, or AppKit collapses the window before dividers are positioned.
- **Column layout is `MainSplitViewController: NSSplitViewController`**, four `NSSplitViewItem`s each hosting SwiftUI via its own `NSHostingController` with `sizingOptions = []`. Divider positions are pinned via `splitView.setPosition(_:ofDividerAt:)` in `viewDidAppear()` (not derivable from `minimumThickness` or a hosting controller's frame). **Cross-column arrow-key focus navigation is not wired up** — each column has its own `NSHostingController`, so there's no shared `@FocusState` (see "Not yet implemented").
- **Per-column toolbar items are done via AppKit**: `MainToolbarDelegate` pins the branch-selector menu to the branches|files divider with `NSTrackingSeparatorToolbarItem`. A toolbar-hosted SwiftUI view must keep the *default* `NSHostingView` sizing (no `sizingOptions = []`) and avoid `.fixedSize()`, or it pops out of the tracking region far earlier than necessary. (A pure-SwiftUI per-column toolbar was tried and abandoned first — SwiftUI's own toolbar placements can't pin to an interior column.)
- **Diff pane is a real `NSTextView`** (`DiffCodeTextView.swift`), built on legacy TextKit 1 explicitly (`makeLegacyTextKit1()`) — the default initializer can come back TextKit 2-backed with no `.layoutManager`. Gutter is a separate `NSView` so line numbers never end up in a selection/copy. Word diff is a simple prefix/suffix trim, not real LCS/Myers.
- **Syntax highlighting** (`HighlightSwift`/highlight.js via JSC) is async and tags results to the diff text they were computed for, so stale highlights can't paint over a newly-selected file. Skipped above ~2000 lines (`DiffView.maxHighlightedLineCount`).
- **`BranchListView`'s `List(selection:)` binding must ignore `nil` in its setter** — macOS fires a spurious `nil` deselect before every real click.
- **Git quotes ambiguous pathnames** (spaces, quotes, non-ASCII) as C-style escaped strings in porcelain output — always parse through `GitRepository.unquoteGitPath(_:)` or later `checkout`/`clean`/`add` calls silently no-op.
- **Sidebar (`SidebarViewController`) is a real `NSOutlineView`**, not SwiftUI `List` — needed for native drag-reorder (a pure-SwiftUI `.draggable`/`.dropDestination` attempt had dead zones between rows). Don't set `outlineTableColumn` (reserves disclosure space on every row regardless of indentation). `NSHostingView` reuse identifiers must be unique per item id, or AppKit's view-reuse hands a row stale `@State`. Gate a row's `.onTapGesture` structurally (e.g. `if` inside `.overlay`) so it doesn't swallow clicks meant for a child `TextField`.
- **Progressive titlebar/traffic-light scroll blur** (`NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle`, macOS 26.1) only engages for a scroll view that's a direct AppKit descendant of its own split item's view controller (why the sidebar isn't SwiftUI-hosted). Also needs: the outline view's `.sourceList` background left alone, `wantsLayer = true` on both the sidebar root view and the split view, a real vertical `NSScroller`, and a top `NSSplitViewItemAccessoryViewController` with `preferredScrollEdgeEffectStyle = .soft`. Missing any one silently no-ops.
- **SwiftUI `.onKeyPress` fires based on `@FocusState` matching, not which nested AppKit responder actually has key focus** — check `NSApp.keyWindow?.firstResponder is NSTextView` and return `.ignored` where relevant, so editing a hosted rename field doesn't hijack the keystroke.
- **`TruncationTooltip`'s hidden "ideal width" probe must reuse the modified `content` view itself**, not a fresh `Text(text)` — a fresh one doesn't inherit caller-applied `.font`/`.fontWeight`.
- **Merge** (`GitRepository.merge(branch:)`) uses `runRaw`, not the throwing `run` — a conflicting merge exits 1 by git's own design, indistinguishable by exit code alone from a genuine error. The reliable discriminator is `.git/MERGE_HEAD` presence (`isMergeInProgress()`).
- **A conflict isn't "resolved" just because the file was hand-edited** — `git status` keeps reporting a path as unmerged (`UU`) until it's staged; `GitRepository.markResolved(_:)` does the `git add`.
- **`FileChangeStatus.conflicted` needs the full two-letter porcelain code** (`UU`/`AA`/`DD`/`AU`/`UA`/`DU`/`UD`) checked before the single-char fallback — some conflict codes contain no `U` at all.
- **`completeMerge()`'s `git commit` must pass `--cleanup=strip` explicitly** — plain `-m` defaults to `--cleanup=whitespace`, which doesn't strip the `# Conflicts:` comment lines from `MERGE_MSG`.
- **A conflicted file's raw contents (with `<<<<<<<`/`=======`/`>>>>>>>` markers) aren't unified-diff output** — `DiffView.parse(_:)` requires `@@` hunk headers and silently drops everything else; `DiffView.parsePlainText(_:)` is used instead when `selectedFile?.status == .conflicted`.
- **Stash is single-slot in the UI** — `AppState`/`BranchListView`/`ChangedFilesView` only ever surface `stash@{0}`, no picking which stash entry to view/apply.
- **Sparkle auto-update**: `UpdaterHolder` holds the single `SPUStandardUpdaterController`, touched once at launch by `AppDelegate`; `LeafApp`'s "Check for Updates…" command reaches the same instance through that holder (SwiftUI `.commands` are declared independently of `AppDelegate`/`AppState`). `SUFeedURL` points at `appcast.xml` at the repo root.
- **Custom Info.plist keys need `INFOPLIST_FILE`, not `INFOPLIST_KEY_*`** — `INFOPLIST_KEY_<Key>` only synthesizes keys from Xcode's fixed known-key list, which Sparkle's keys aren't on. `Leaf/Info.plist` is merged in via `INFOPLIST_FILE` alongside `GENERATE_INFOPLIST_FILE = YES`, and excluded from Copy Bundle Resources via a `PBXFileSystemSynchronizedBuildFileExceptionSet` (otherwise it also gets copied in verbatim alongside the merged one).
- **Release**: `scripts/make_dmg.sh` builds Release, re-signs the app + Sparkle's nested helpers with the Developer ID Application identity, notarizes (`notarytool submit --wait`) and staples, then packages the DMG. Confirmed working end-to-end (v0.4.0 released via GitHub Releases, Sparkle successfully auto-updated in-app). `.github/workflows/ci.yml` (`workflow_dispatch` only) runs build+test on `macos-latest` with signing disabled; not yet confirmed green on a real push.
- **Diff hunks have no header row** — `HunkSeparatorOverlayView`/gutter borders mark hunk boundaries instead of `@@ ... @@` text.

## Not yet implemented

Multi-entry stash browsing (apply/drop/view a specific `stash@{n}`, not just the top of the stack). A real 3-way ours/theirs conflict diff view.
