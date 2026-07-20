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

`CurrentTests` and `CurrentUITests` currently contain only Xcode's placeholder templates — no real tests exist yet.

Target: macOS 26.5 deployment, Swift 5, `garrill.Current` bundle ID. **App Sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`) — required because the app needs to open and shell out inside arbitrary repo folders anywhere on disk; this is a deliberate, non-default choice for a personal dev tool, not an oversight.

Source files are picked up automatically via Xcode's file-system-synchronized groups (`PBXFileSystemSynchronizedRootGroup`) — new `.swift` files added under `Current/` do **not** need to be manually added to `project.pbxproj`.

## Architecture

**Git backend: shells out to the system `git` CLI, not libgit2/SwiftGit2.** This was a deliberate pivot — see `Current/Models/GitRepository.swift`. SwiftGit2 was tried first but has no SPM package that reliably links for native macOS arm64 (the official repo has no SPM support at all; forks either ship iOS/Mac-Catalyst-only binaries or have iOS-only SSH/SSL dependencies). All git operations run via `Process` against `/usr/bin/git` with the repo path as the working directory, and parse plumbing-friendly output (`status --porcelain=v1 --untracked-files=all`, `for-each-ref`, `log` with a `\u{1F}`-delimited custom format, `show --name-status`). `GitRepository.run()` throws `GitError.commandFailed` on non-zero exit; `runRaw()` is used instead for commands (like `diff --no-index`) that use their exit code to mean "differences found" rather than "failure".

**Data flow is unidirectional through a single `@Observable AppState`** (`Current/ViewModels/AppState.swift`), which owns everything: selected repo → `GitRepository` (a stateless value wrapping a root `URL`, constructed on demand) → branches/commits → selected `ChangeSource` (either `.workingChanges` or a specific `.commit(GitCommit)`) → changed files → selected file → diff text. There is no separate "refresh" plumbing per column — selecting anything upstream (`selectRepo`, `selectBranch`, `selectSource`, `selectFile`) synchronously re-fetches everything downstream of it via git calls on the main thread (fine for local repos at this scale; would need to move off the main thread if this becomes a problem for large repos).

**Views are 1:1 with the 4 columns** (`Current/Views/`): `RepoListView`, `BranchListView`, `ChangedFilesView`, `DiffView`, assembled by `MainWindowView`. `BranchListView` doubles as the branch switcher (a `Picker` that triggers `git checkout`) and the source selector (a `List` mixing a fixed "Uncommitted Changes" row with a "History" section of commits — both tagged with the `ChangeSource` enum).

**Column layout is hand-rolled, not `HSplitView`/adaptive `NavigationSplitView` defaults**, after hitting real layout bugs:
- Column 1 (repos) lives in `NavigationSplitView`'s sidebar slot for native sidebar vibrancy/material, but with `.navigationSplitViewStyle(.balanced)` — the default style lets the sidebar collapse into a sliding overlay when the window gets narrow, which was rejected.
- Columns 2–3 (branches, files) are plain `HStack` children with explicit `@State` pixel widths, resized only by dragging `ResizableDivider` (`Current/Views/ResizableDivider.swift`). `HSplitView` was tried first but recalculates pane sizes whenever a child view's structure changes (e.g. swapping `List` ↔ `ContentUnavailableView`), causing visible jumps on selection.
- Because of that, every column view keeps its `List` **permanently mounted** and uses `ZStack` + `.opacity()` to show empty/error states, rather than conditionally swapping the root view type — this was necessary to stop AppKit from relaying out (and visibly shrinking) the pane on every selection change.
- `ResizableDivider`'s drag gesture uses `.global` coordinate space, not the default `.local` — `.local` translation is relative to the divider's own frame, which moves as the width it's dragging changes, creating a feedback loop (half-speed, oscillating drag).
- The window's `minWidth` is computed live from the current column `@State` widths + a fixed diff-pane minimum, so dragging a column wider also raises the window's minimum resize size — the layout can never end up clipped.

**Commit flow**: `ChangedFilesView` shows per-file checkboxes (checked by default) only when viewing `.workingChanges`; `AppState.checkedFilePaths` tracks which are included. Committing runs `git add -- <checked paths>` then `git commit -m <message>` (plain, not pathspec-limited — `git commit -- <pathspec>` fails on untracked files, so explicit `add` first is required) via `GitRepository.commit(message:paths:)`, then triggers a full `refreshRepositoryState()`.

## Not yet implemented

Per the original planning doc (roughly, in order): unstage/discard individual changes, fetch/pull/push with credential handling, merge/conflict UI, stash, repo auto-refresh on external changes (FSEvents), binary/image diff rendering (currently just renders whatever `git diff` outputs as monospaced text).
