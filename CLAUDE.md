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
- **Sidebar (`RepoListView`) is a real `NSOutlineView`** (`SidebarOutlineView.swift`, `NSViewRepresentable` + coordinator), not a SwiftUI `List` — needed for native drag-reorder with a system-drawn insertion line and "drop on a folder" highlight; a pure-SwiftUI `.draggable`/`.dropDestination` attempt had unfixable dead zones between rows. Row content (`RepoRowView`/`FolderRowView`) is hosted per-cell via `NSHostingView`. Gotchas: don't set `outlineTableColumn` — it reserves native disclosure-triangle space on every row (even level-0) regardless of `indentationPerLevel`; indentation and the expand/collapse chevron are fully custom instead, driven by calling `expandItem`/`collapseItem` directly. `NSHostingView` reuse identifiers must be unique per item id (not shared as one pool key across all folders/repos), or AppKit's view-reuse can hand a row a different item's stale SwiftUI `@State` (rename draft text, focus). A `.onTapGesture` on a row swallows clicks meant for a child `TextField` even if the closure itself checks a condition first — gate it structurally (e.g. only attach via `if` inside `.overlay`) instead.
- **SwiftUI `.onKeyPress` at an ancestor view fires based on `@FocusState` matching, not on which nested AppKit responder actually has key focus** — arrow-key column-switching in `MainWindowView` had to check `NSApp.keyWindow?.firstResponder is NSTextView` and return `.ignored` so editing a hosted rename field doesn't hijack the keystroke.
- **`TruncationTooltip`'s hidden "ideal width" probe must reuse the modified `content` view itself**, not a fresh `Text(text)` — a fresh one doesn't inherit caller-applied `.font`/`.fontWeight`, throwing off the width comparison and reporting truncation that isn't real.
- **Merge** (`GitRepository.merge(branch:)`) uses `runRaw`, not the throwing `run` — a conflicting merge exits 1 by git's own design, not as a process failure, and exit code alone can't tell that apart from a genuine error (dirty worktree, unrelated histories also exit 1). The reliable discriminator is `.git/MERGE_HEAD` presence after a non-zero exit (`isMergeInProgress()`) — git's own ground truth for "stopped mid-merge." Same file exposes `mergeMessage()` (reads `.git/MERGE_MSG`, prefills the commit box) and `mergeAbort()`.
- **A conflict isn't "resolved" just because the file was hand-edited** — `git status` keeps reporting a path as unmerged (`UU`) until it's staged. `GitRepository.markResolved(_:)` (`git add`) is what actually flips the status; the "Mark Resolved" button in `ChangedFilesView` calls it. Without this step `completeMerge()`'s "any file still `.conflicted`" gate never clears.
- **`FileChangeStatus.conflicted` detection needs the full two-letter porcelain code** (`UU`/`AA`/`DD`/`AU`/`UA`/`DU`/`UD`), checked in `statusEntries()` *before* the normal single-char fallback — some conflict codes (`AA`, `DD`) contain no `U` at all, so they can't be derived from either status char alone.
- **`completeMerge()`'s `git commit` must pass `--cleanup=strip` explicitly** — plain `-m` defaults to `--cleanup=whitespace`, which does *not* strip comment lines, so the `# Conflicts:\n#\tfile` lines from `MERGE_MSG` (prefilled into the commit box) would otherwise get baked verbatim into the real commit message.
- **A conflicted file's raw contents (with `<<<<<<<`/`=======`/`>>>>>>>` markers) aren't unified-diff output** — `DiffView.parse(_:)` requires `@@` hunk headers and silently drops every line until it sees one, so feeding conflict-marker text through it renders as blank. `DiffView.parsePlainText(_:)` is the separate path used instead when `selectedFile?.status == .conflicted`.

## Not yet implemented

stash. (Branch merging — including conflict detection/resolution — is implemented; see `GitRepository.merge`/`mergeAbort`/`completeMerge`/`markResolved`. Not yet done: a real 3-way ours/theirs diff view, and promoting `BranchListView` from a commit-history-only view into an actual branch list — the merge entry point currently lives in `MainWindowView`'s toolbar branch menu instead.)
