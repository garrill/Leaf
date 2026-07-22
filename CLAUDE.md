# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

`Current`: native SwiftUI macOS git client, 4-column layout (repos → branches/history → changed files → diff). Early-stage, not feature-complete — see "Not yet implemented".

## Build, run, test

No Package.swift — plain Xcode project (`Current.xcodeproj`), scheme `Current`.

```sh
xcodebuild -project Current.xcodeproj -scheme Current -configuration Debug build
xcodebuild -project Current.xcodeproj -scheme Current test
open /path/to/DerivedData/.../Build/Products/Debug/Current.app
```

- Quit any running instance before relaunching (`osascript -e 'tell application "Current" to quit'`) — xcodebuild won't overwrite a running bundle.
- Don't try to screenshot/screen-record the app (no permission in this terminal) — build, launch, let the user verify visually.
- `CurrentTests`/`CurrentUITests` are still just Xcode placeholders — no real tests exist.
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) deliberately — app shells out inside arbitrary repo folders on disk.
- `.swift` files under `Current/` are picked up automatically (file-system-synchronized groups) — never need adding to `project.pbxproj`.

## Architecture gotchas

- **Git backend shells out to `/usr/bin/git`**, not libgit2/SwiftGit2 (no SPM package reliably links for macOS arm64).
- **AppState is the single source of truth.** Selection changes (`selectRepo`/`selectBranch`/`selectSource`/`selectFile`) are synchronous on the main thread, re-fetching everything downstream via git calls — fine at current scale, revisit if repos get large. Fetch/pull/push are the exception: they run via `Task { try await Task.detached { ... } }` with explicit `MainActor.run` hops back. A `RepoWatcher` (FSEvents) drives `handleExternalChange()` for auto-refresh on out-of-band changes to the working tree.
- **Liquid Glass column header blur** requires `.safeAreaBar(edge: .top)` (not `.safeAreaInset`) paired with `.scrollEdgeEffectStyle(.soft, for: .top)`, and only works over a real SwiftUI `ScrollView`/`List` — never over an `NSScrollView` wrapped in `NSViewRepresentable`. The bar also needs genuine non-empty content (`EmptyView()`/`Text("")` don't render/blur).
- **No general `.glassEffect()` modifier exists** in the macOS 26.5 SDK — only `.buttonStyle(.glass/.glassProminent)`.
- **Window chrome**: `WindowAccessor.swift` sets `titlebarAppearsTransparent`/`.fullSizeContentView` directly on `NSWindow` to keep traffic lights while removing toolbar chrome — don't use `.windowStyle(.hiddenTitleBar)` (leaves dead space). Window title is set via `.navigationTitle(_:)`, never `NSWindow.title` from the accessor (races SwiftUI, gets stuck).
- **Column layout is hand-rolled** (`HStack` + `@State` widths + `ResizableDivider`), not `HSplitView`, which visibly jumps on selection. Every column keeps its `List` permanently mounted, swapping empty/error states via `ZStack`/`.opacity()`. `ResizableDivider`'s drag gesture must use `.global` coordinate space (`.local` causes oscillating drag).
- **Commit** (`GitRepository.commit(message:paths:unstagePaths:)`) does `git reset -- <unstagePaths>` (if any), then `git add -- <paths>`, then plain `git commit -m` — pathspec-limited commit fails on untracked files.
- **Diff pane is a real `NSTextView`** (`DiffCodeTextView.swift`), not SwiftUI `Text` rows — needed for real multi-line selection. Built on legacy TextKit 1 explicitly (`makeLegacyTextKit1()`), not the default initializer (can come back TextKit 2-backed with no `.layoutManager`). Gutter is a separate plain `NSView` outside the text view so line numbers never end up in a selection/copy. Added/removed backgrounds are full-row-width, painted manually in `draw(_:)`. Word diff is a simple prefix/suffix trim, not real LCS/Myers.
- **Syntax highlighting** (`HighlightSwift`/highlight.js via JSC) is async and must never block text appearing; results are tagged to the diff text they were computed for so stale highlights can't paint over a newly-selected file. Skipped above ~2000 lines (`DiffView.maxHighlightedLineCount`) to avoid jank.
- **`BranchListView`'s `List(selection:)` uses an `Optional` binding that must ignore `nil` in its setter** — macOS fires a spurious `nil` deselect before every real click; passing it through flashes the diff pane empty. `ChangedFilesView` instead binds `Set<String>` for native multi-select; `AppState.updateFileSelection(_:)` reconciles that against the single file the diff pane shows.
- **Git quotes ambiguous pathnames** (spaces, quotes, non-ASCII) in porcelain/name-status output as C-style escaped strings — always parse through `GitRepository.unquoteGitPath(_:)` or later `checkout`/`clean`/`add` calls silently no-op.
- **Repo icons** (`IconComposerRenderer.swift`) are a hand-rolled approximation of Apple's `.icon` bundle format — there's no public API to rasterize one at runtime. Not pixel-accurate; fine for a sidebar glyph.
- **Reparenting repos into folders is a "Move to Group" context-menu action, not drag-and-drop** — a prior drag-based attempt (reorder + nest in one gesture) was unreliable and was abandoned; don't redo it that way.

## Not yet implemented

merge/conflict UI, stash.
