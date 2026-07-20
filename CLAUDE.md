# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Current` is a native SwiftUI macOS git client (a minimal GitHub Desktop / Changes-style app), built around a 4-column layout: repos → branches/history → changed files → unified diff. It is an early-stage personal project, not yet feature-complete (see the "Not yet implemented" section below).

## Build, run, test

There is no Package.swift — this is a plain Xcode project (`Current.xcodeproj`), scheme `Current`.

```sh
# Build
xcodebuild -project Current.xcodeproj -scheme Current -configuration Debug build

# Run tests (CurrentTests + CurrentUITests targets)
xcodebuild -project Current.xcodeproj -scheme Current test

# Launch the built app after a build
open /path/to/DerivedData/.../Build/Products/Debug/Current.app
```

After code changes, quit any running instance before relaunching (`osascript -e 'tell application "Current" to quit'`) since Xcode/xcodebuild won't overwrite a running app bundle cleanly.

Don't bother trying to screen-record or screenshot the app to visually verify changes (this session's terminal generally lacks screen-recording permission anyway) — build it, launch it, and let the user do the visual testing themselves.

`CurrentTests` and `CurrentUITests` currently contain only Xcode's placeholder templates — no real tests exist yet.

Target: macOS 26.5 deployment, Swift 5, `garrill.Current` bundle ID. **App Sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`) — required because the app needs to open and shell out inside arbitrary repo folders anywhere on disk; this is a deliberate, non-default choice for a personal dev tool, not an oversight.

Source files are picked up automatically via Xcode's file-system-synchronized groups (`PBXFileSystemSynchronizedRootGroup`) — new `.swift` files added under `Current/` do **not** need to be manually added to `project.pbxproj`.

## Architecture

**Git backend: shells out to the system `git` CLI, not libgit2/SwiftGit2.** This was a deliberate pivot — see `Current/Models/GitRepository.swift`. SwiftGit2 was tried first but has no SPM package that reliably links for native macOS arm64 (the official repo has no SPM support at all; forks either ship iOS/Mac-Catalyst-only binaries or have iOS-only SSH/SSL dependencies). All git operations run via `Process` against `/usr/bin/git` with the repo path as the working directory, and parse plumbing-friendly output (`status --porcelain=v1 --untracked-files=all`, `for-each-ref`, `log` with a `\u{1F}`-delimited custom format, `show --name-status`). `GitRepository.run()` throws `GitError.commandFailed` on non-zero exit; `runRaw()` is used instead for commands (like `diff --no-index`) that use their exit code to mean "differences found" rather than "failure".

**Data flow is unidirectional through a single `@Observable AppState`** (`Current/ViewModels/AppState.swift`), which owns everything: selected repo → `GitRepository` (a stateless value wrapping a root `URL`, constructed on demand) → branches/commits → selected `ChangeSource` (either `.workingChanges` or a specific `.commit(GitCommit)`) → changed files → selected file → diff text. There is no separate "refresh" plumbing per column — selecting anything upstream (`selectRepo`, `selectBranch`, `selectSource`, `selectFile`) synchronously re-fetches everything downstream of it via git calls on the main thread (fine for local repos at this scale; would need to move off the main thread if this becomes a problem for large repos).

**Views are 1:1 with the 4 columns** (`Current/Views/`): `RepoListView`, `BranchListView`, `ChangedFilesView`, `DiffView`, assembled by `MainWindowView`. `BranchListView` doubles as the branch switcher (a `Menu` styled as a glass capsule pill via `.buttonStyle(.glass)` + `.buttonBorderShape(.capsule)`, not a `Picker`, so it can get the Liquid Glass look) and the source selector (a `List` mixing a fixed "Uncommitted Changes" row with a "History" section of commits — both tagged with the `ChangeSource` enum).

**Column 1 (`RepoListView`) is a flat list with a manually-flattened tree, not `OutlineGroup`.** Repos can live in single-level folders (no nesting) with per-repo display-name overrides and custom icons (`Current/Models/SidebarModels.swift`: `SidebarRepo`, `SidebarFolder`, `TopLevelEntry`). State lives in `SidebarStore` (`Current/Models/SidebarStore.swift`), persisted as JSON under the `"sidebarState.v2"` `UserDefaults` key, migrated once from the old `repoPaths: [String]` key. Reordering (folders and repos among siblings, either at the top level or within one folder) uses native `.onMove` — an outer `ForEach` over `topLevelOrder` plus a separate inner `ForEach` per expanded folder's children, each with its own `onMove`, giving the real system drag insertion-line for free. Reparenting (moving a repo into or out of a folder) is deliberately **not** drag-and-drop — it's a "Move to Folder" context-menu submenu on each repo row (`SidebarStore.moveRepo(id:toFolder:index:)`). This was a downgrade from an earlier drag-based nesting attempt: `.onMove` can only reorder within one `ForEach` and can't express "drop onto a folder to nest into it", and a hand-rolled `DropDelegate` that tried to support both reordering and nesting in a single continuous drag (tracking pointer position within each row to infer above/inside/below) shipped with unreliably small hit targets and stuck-indicator artifacts. If drag-based reparenting is revisited, don't repeat that approach.

**macOS 26 "Liquid Glass" touches — scroll edge effect and window chrome.** Each column header (repo name + branch menu, files count, diff file name) sits in a `.safeAreaBar(edge: .top)` — **not** `.safeAreaInset` — paired with `.scrollEdgeEffectStyle(.soft, for: .top)` on the scrollable view underneath it; that pairing is the actual API behind the native "blurred, fading" bar seen in Finder/Mail/Xcode. `.safeAreaInset` alone renders nothing there (fully transparent, no automatic backing) — this wasn't discovered by guessing but by reading the source of [github.com/maoyama/Changes](https://github.com/maoyama/Changes), an open-source SwiftUI macOS git client with the same effect on its own bottom bar; worth checking for other native-pattern questions on this project. There is **no general `.glassEffect()` view modifier** in the macOS 26.5 SDK — only `GlassButtonStyle`/`GlassProminentButtonStyle` (`.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`), so any frosted-glass look on non-button controls has to be built from those button styles (e.g. the branch menu above), not a general-purpose modifier. The window itself has no title bar or toolbar strip: `Current/Views/WindowAccessor.swift` is an `NSViewRepresentable` that reaches into the hosting `NSWindow` directly (`titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, inserts `.fullSizeContentView`, `toolbar = nil`) so content extends to the literal top of the window while the traffic lights stay visible and functional. `.windowStyle(.hiddenTitleBar)` + `.toolbar(.hidden, for: .windowToolbar)` was tried first and left dead reserved space with the traffic lights gone entirely — don't reach for that combination again.

**Column layout is hand-rolled, not `HSplitView`/adaptive `NavigationSplitView` defaults**, after hitting real layout bugs:
- Column 1 (repos) lives in `NavigationSplitView`'s sidebar slot for native sidebar vibrancy/material, but with `.navigationSplitViewStyle(.balanced)` — the default style lets the sidebar collapse into a sliding overlay when the window gets narrow, which was rejected.
- Columns 2–3 (branches, files) are plain `HStack` children with explicit `@State` pixel widths, resized only by dragging `ResizableDivider` (`Current/Views/ResizableDivider.swift`). `HSplitView` was tried first but recalculates pane sizes whenever a child view's structure changes (e.g. swapping `List` ↔ `ContentUnavailableView`), causing visible jumps on selection.
- Because of that, every column view keeps its `List` **permanently mounted** and uses `ZStack` + `.opacity()` to show empty/error states, rather than conditionally swapping the root view type — this was necessary to stop AppKit from relaying out (and visibly shrinking) the pane on every selection change.
- `ResizableDivider`'s drag gesture uses `.global` coordinate space, not the default `.local` — `.local` translation is relative to the divider's own frame, which moves as the width it's dragging changes, creating a feedback loop (half-speed, oscillating drag).
- The window's `minWidth` is computed live from the current column `@State` widths + a fixed diff-pane minimum, so dragging a column wider also raises the window's minimum resize size — the layout can never end up clipped.

**Commit flow**: `ChangedFilesView` shows per-file checkboxes (checked by default) only when viewing `.workingChanges`; `AppState.checkedFilePaths` tracks which are included. Committing runs `git add -- <checked paths>` then `git commit -m <message>` (plain, not pathspec-limited — `git commit -- <pathspec>` fails on untracked files, so explicit `add` first is required) via `GitRepository.commit(message:paths:)`, then triggers a full `refreshRepositoryState()`.

## Not yet implemented

Per the original planning doc (roughly, in order): unstage individual changes (discarding is implemented — `GitRepository.discardChanges(for:)`, wired to a context-menu item in `ChangedFilesView`), fetch/pull/push with credential handling, merge/conflict UI, stash, repo auto-refresh on external changes (FSEvents), binary/image diff rendering (currently just renders whatever `git diff` outputs as monospaced text).
