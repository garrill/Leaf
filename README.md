<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Leaf app icon">
</p>

<h1 align="center">Leaf</h1>

<p align="center">A fast, native git client for macOS.</p>

Leaf is a 4-column git client — repos, branches & history, changed files, and diff, side by
side — built to feel like a first-party Mac app rather than a cross-platform tool wearing a Mac
costume. It talks to git directly (no bundled/embedded git implementation), so it behaves exactly
like the git you already have installed, with your existing config, credentials, and hooks.

It's in active development and heading toward a first beta, but the core day-to-day workflow —
browsing history, staging and committing, diffing, branching, merging, and stashing — already
works end to end.

## Features

- **Multi-repo sidebar** — group repositories into folders, drag to reorder, drag a folder in
  straight from Finder to add it, right-click a group to sort its contents alphabetically
- **Full working-copy workflow** — stage, unstage, and commit; discard changes; stash; resolve
  conflicts
- **Branching & merging** — create, switch, and merge branches, with conflict detection and a
  guided resolve-and-complete flow
- **Rich diff viewer** — syntax-highlighted, word-level diffs in a real native text view (proper
  multi-line selection, not a SwiftUI text hack), plus image diffs for binary assets
- **Fetch, pull, and push**, with ahead/behind status always visible
- **Clone straight into the sidebar**, or add an existing local repository with a picker or a
  Finder drag
- **Auto-refresh** — the working tree updates live when files change outside the app (via FSEvents)
- Clear guidance if git itself isn't available on your Mac, with a one-click path to install it

## Requirements

- macOS with Xcode (targets the macOS 26 SDK / Liquid Glass APIs)
- git — Leaf will detect if it's missing and help you install it
- No external dependencies to build — no `Package.swift`, no SPM packages

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

## Architecture, at a glance

- **Git backend**: shells out to `/usr/bin/git` directly (no libgit2/SwiftGit2) — see
  `GitRepository.swift`.
- **State**: `AppState` is the single source of truth for the whole app.
- **Layout**: a native AppKit `NSSplitViewController` (sidebar | branches/history | files | diff),
  hosting each column as its own SwiftUI view — not a cross-platform layout, a genuinely native one.
- **Sidebar**: a hand-wired `NSOutlineView` for native drag-reorder, not a SwiftUI `List`.
- **Diff view**: a real `NSTextView`, not SwiftUI `Text`, for proper multi-line selection.
- App Sandbox is intentionally disabled — the app shells out inside arbitrary repo folders on disk.

See `CLAUDE.md` for detailed implementation notes and the reasoning behind these choices, and
`ROADMAP.md` for what's left before a first beta.

## Status

Not yet implemented: browsing multiple stash entries (only the top of the stack), a real 3-way
ours/theirs conflict diff view, and a dedicated branch list (branch switching and merging already
work, via the toolbar).

## Testing

`LeafTests`/`LeafUITests` are currently just Xcode placeholders — no real tests exist yet
(see `ROADMAP.md`).

```sh
xcodebuild -project Leaf.xcodeproj -scheme Leaf test
```
