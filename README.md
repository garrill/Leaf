<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Leaf app icon">
</p>

<h1 align="center">Leaf</h1>

<p align="center">A lightweight, native git client for macOS.</p>

Leaf is a free and open-source git client for MacOS. It is based on a four column layout to show repositories, branch history, changed files and file diffs all side-by-side. It talks to the git you have installed directly, so it has your config, credentials, and hooks.

This is intentionally a bare-bones, simple to use git client, best for solo devs / small teams working on repositories with a few branches. It doesn't handle the more complex side of git and there are no plans to add more features.

## Installation

Download the latest `.dmg` from the [GitHub Releases page](https://github.com/garrill/Leaf/releases).

## Features

- **Multi-repo sidebar** group repositories into folders, then reorder, rename and add icons to repos to help organisation
- **Basic git workflow** — switch and merge branches; commit, stage and unstage files; fetch, pull and push; add and remove tags
- **Rich diff viewer** — syntax-highlighted, word-level diffs, plus side by-side or swipe over image diffs

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img src="docs/screenshot-light.png" alt="Leaf screenshot">
</picture>

## Requirements

- macOS with Xcode (minimum MacOS 26)
- git — Leaf will detect if it's missing and help you install it
- No `Package.swift` manifest — this is a plain Xcode project, not an SPM package

## Building & running

There's no `Package.swift`; this is a plain Xcode project. It does pull in two SPM dependencies (`HighlightSwift`, `Sparkle`) via Xcode's own package resolution, which happens automatically on first build.

```sh
xcodebuild -project Leaf.xcodeproj -scheme Leaf -configuration Debug build
open /path/to/DerivedData/.../Build/Products/Debug/Leaf.app
```

Or open `Leaf.xcodeproj` in Xcode and run the `Leaf` scheme.

Quit any running instance before rebuilding — `xcodebuild` won't overwrite a running app bundle:

```sh
osascript -e 'tell application "Leaf" to quit'
```

## Architecture, at a glance

- **Git backend**: shells out to `/usr/bin/git` directly (no libgit2/SwiftGit2) — see `GitRepository.swift`.
- **State**: `AppState` is the single source of truth for the whole app.
- **Layout**: `NSSplitViewController` (sidebar | branches/history | files | diff), hosting each column as its own SwiftUI view.
- **Sidebar**: `NSOutlineView` for native drag-reorder.
- **Diff view**: `NSTextView`, for proper multi-line selection.
- App Sandbox is intentionally disabled — the app shells out inside arbitrary repo folders on disk.

## Privacy

Leaf runs entirely on your Mac. It talks only to the git you already have installed and to the remotes you configure — nothing about your repositories, code, or usage is collected or sent anywhere.

## Testing

`LeafTests` has real unit tests against `GitRepository`, run against throwaway repos in a temp directory (real `git`, no mocks) — see `LeafTests/LeafTests.swift`. `LeafUITests` has a handful of real `XCUIApplication` tests (launch, empty state, Settings window, menu contents) — see `LeafUITests/LeafUITests.swift`; `LeafUITestsLaunchTests.swift` is still the stock Xcode placeholder.

```sh
xcodebuild -project Leaf.xcodeproj -scheme Leaf test
```

## License

MIT — see [LICENSE](LICENSE).
