# Leaf

A native SwiftUI git client for macOS.

Leaf is a 4-column git client (repos → branches/history → changed files → diff), built directly on `/usr/bin/git` rather than a bundled libgit2. It's early-stage and not feature-complete, but the core workflow — browsing history, staging/committing, diffing, branching, and merging — works end to end.

## Features

- Multi-repo sidebar with drag-to-reorder and folder grouping (native `NSOutlineView`), plus repo cloning
- Branch/commit history column
- Changed files view with staging, unstaging, and commit
- Rich diff pane with syntax highlighting and word-level diffs (native `NSTextView`, real multi-line selection)
- Image diffs
- Fetch, pull, push
- Branch merging, including conflict detection and resolution
- Auto-refresh on out-of-band working-tree changes (FSEvents via `RepoWatcher`)

### Not yet implemented

- Stash
- A real 3-way ours/theirs diff view
- `BranchListView` is currently commit-history-only, not a full branch list (branch merge is available via the toolbar branch menu)

## Requirements

- macOS with Xcode (targets the macOS 26 SDK / Liquid Glass APIs)
- No external dependencies — no Package.swift, no SPM packages

## Building & running

There's no `Package.swift`; this is a plain Xcode project.

```sh
xcodebuild -project Leaf.xcodeproj -scheme Leaf -configuration Debug build
open /path/to/DerivedData/.../Build/Products/Debug/Leaf.app
```

Or just open `Leaf.xcodeproj` in Xcode and run the `Leaf` scheme.

Quit any running instance before rebuilding — `xcodebuild` won't overwrite a running app bundle:

```sh
osascript -e 'tell application "Leaf" to quit'
```

## Architecture

- **Git backend**: shells out to `/usr/bin/git` (no libgit2/SwiftGit2) — see `GitRepository.swift`.
- **State**: `AppState` is the single source of truth; most selection changes re-fetch synchronously on the main thread. Fetch/pull/push run off the main thread via `Task`/`Task.detached`.
- **Layout**: a native 3-column `NavigationSplitView` (sidebar | history | detail) with an `HSplitView` inside the detail pane (files | diff). No custom resizable-divider code.
- **Sidebar**: a hand-wired `NSOutlineView` (`SidebarOutlineView.swift`) for native drag-reorder, not a SwiftUI `List`.
- **Diff view**: a real `NSTextView` (`DiffCodeTextView.swift`), not SwiftUI `Text`, needed for proper multi-line selection.
- App Sandbox is intentionally disabled — the app shells out inside arbitrary repo folders on disk.

See `CLAUDE.md` for detailed implementation notes, gotchas, and rationale behind these choices.

## Testing

`LeafTests`/`LeafUITests` are currently just Xcode placeholders — no real tests exist yet.

```sh
xcodebuild -project Leaf.xcodeproj -scheme Leaf test
```
