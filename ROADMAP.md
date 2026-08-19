# Leaf — Beta Readiness Roadmap

Working name during this rewrite: **Current → Leaf** (see below). This file tracks what's
left before an initial beta release. Check items off as they land; add new ones as they
turn up.

**Distribution decision (2026-08-12):** ship direct-distribution (notarized DMG, outside
the Mac App Store) with Sparkle for auto-update. App Sandbox stays off — the git backend
keeps shelling out to `/usr/bin/git` unchanged. Mac App Store + sandboxing is a separate
future decision, not required for beta; revisit only if we want MAS distribution later; at
that point expect a real research spike (security-scoped bookmarks per repo, whether a
sandboxed process can still spawn `/usr/bin/git` against arbitrary user-selected paths, and
possibly a libgit2/SwiftGit2 rewrite of `GitRepository`).

---

## 1. Rename: Current → Leaf

Full rename — repo folder, project files, and all in-code references, not just the
product-facing name.

- [x] Rename repo directory `Current` → `Leaf`
- [x] Rename `Current.xcodeproj` → `Leaf.xcodeproj`, scheme `Current` → `Leaf`
- [x] Rename `Current/` source group → `Leaf/`, `CurrentTests` → `LeafTests`,
      `CurrentUITests` → `LeafUITests` (targets, folders, bundle ids
      `garrill.Current`/`garrill.CurrentTests`/`garrill.CurrentUITests` →
      `garrill.Leaf`/etc.)
- [x] `PRODUCT_NAME`/display name → Leaf (2026-08-12). `MARKETING_VERSION` still `1.0` for
      all targets — still need to decide the real starting version for beta (e.g. `0.1.0`)
- [x] App icon: `IconComposerRenderer` already renders `.icon` bundles fine (fixed
      2026-08-12) — the repo's own `Leaf/Leaf.icon` (renamed from `Current.icon`, content
      untouched) is used as a sidebar glyph example, not yet wired in as the actual app
      icon asset (`AppIcon.appiconset` is still empty; `ASSETCATALOG_COMPILER_APPICON_NAME`
      points at a nonexistent "Leaf" iconset — pre-existing mismatch, carried through the
      rename unchanged). A separately designed `~/Leaf.icon` also exists outside the repo
      and hasn't been reviewed/imported.
- [x] Sweep all `.swift` files for `Current`-named types/comments/strings (window title,
      `CurrentApp.swift` → `LeafApp.swift`, any hardcoded "Current" in UI strings) — left
      incidental identifiers like `isCurrent`/`loadChangedFilesForCurrentSelection`/
      `pullCurrentBranch` alone, since those mean "current selection", not the product name
- [x] Update `CLAUDE.md` throughout
- [x] Update `README.md`
- [x] `AppDelegate.swift` — window title strings in `MainWindowController.swift` updated;
      `WindowAccessor.swift` no longer exists in the codebase (window is now fully
      AppKit-owned via `MainWindowController`) — the CLAUDE.md line referencing it under
      "Window chrome" looks stale from before that rewrite, worth a separate cleanup pass
- [x] Local git remote name / GitHub repo rename (if/when a remote exists) — separate,
      confirm with user before touching anything on GitHub

This is mechanical but risks silent breakage (Xcode scheme references, DerivedData paths,
file-system-synchronized groups keyed by folder name) — do it as one dedicated pass with a
full clean build + launch afterward, not interleaved with feature work.

## 2. Test coverage

`LeafTests`/`LeafUITests` are currently empty Xcode placeholders (per CLAUDE.md).
Two different kinds of testing are needed:

### 2a. Automated unit tests against `GitRepository`

Most valuable and most tractable: `GitRepository` shells out to real `git`, so tests can
spin up real throwaway repos in a temp directory per test (`git init`, build up state with
raw `git` commands or via `GitRepository` itself), call the method under test, and assert
on the result. No UI automation needed for this layer.

Coverage matrix, driven off the "Not yet implemented"/gotchas list in CLAUDE.md — worth
enumerating explicitly rather than testing happy-path only:

- [x] Clean repo, no commits yet (`git init` with zero commits)
- [x] Dirty tree: staged / unstaged / untracked / ignored files, all combinations
- [x] Commit with pathspec-limited staging (partial stage + partial unstage in one commit)
- [x] Stash: push/list/apply/pop on the single-slot UI path; also confirm behavior is sane
      when *more than one* stash exists on the underlying repo (multi-entry stash browsing
      is explicitly out of scope for the UI, but the backend shouldn't corrupt state)
- [x] Merge: clean fast-forward, clean merge commit, conflicting merge
      (`isMergeInProgress`/`MERGE_HEAD`), abort, complete with `--cleanup=strip`
- [x] Conflict detection for every two-letter porcelain code: `UU`/`AA`/`DD`/`AU`/`UA`/
      `DU`/`UD` — CLAUDE.md flags `AA`/`DD` specifically as not derivable from a single
      status char (2026-08-12: `UU` via the ordinary conflicting-merge test, `AA` via a
      dedicated both-added test; `DD`/`AU`/`UA`/`DU`/`UD` still only covered by reading the
      code, not exercised individually)
- [x] `markResolved` actually flips status and unblocks `completeMerge`'s gate
- [x] Branch create/switch/delete; branch switch with dirty tree → stash-and-switch path
      (2026-08-12: `GitRepository.checkout` throwing on a dirty tree is covered — the
      `AppState`-level decision to offer stash-and-switch is UI logic, left for 2b)
- [x] Detached HEAD state
- [x] Diverged from origin: ahead-only, behind-only, both (needs a local "remote" — a
      second bare repo on disk works, no network needed)
- [x] Fetch/pull/push against a local bare-repo remote (covers the common path without
      needing real network/auth)
- [ ] Push/pull against something requiring real auth (SSH key or HTTPS credential
      helper) — at least one manual smoke test, since this exercises the user's actual git
      credential config rather than anything Leaf controls
- [x] Ambiguous/quoted paths: filenames with spaces, quotes, non-ASCII — confirms
      `unquoteGitPath` round-trips through status/checkout/clean/add
- [x] Discard changes, ignore files, clean untracked
- [ ] Large diff / large repo performance (thousands of files, a multi-thousand-line
      file) — confirms the >2000-line highlight skip and general responsiveness
- [x] Binary files in diff/status
- [x] Repo with a `.gitignore` covering nested directories
- [x] Submodules (at minimum: doesn't crash / mis-render status — full submodule UI is
      not in scope)
- [x] Bare repo opened by mistake — should fail gracefully, not crash

2026-08-12: `LeafTests/LeafTests.swift` now has ~50 real tests against `GitRepository`
using throwaway temp repos (see `TestRepo` helper there) — covers everything above except
real-auth push/pull and large-repo performance. Along the way this caught and fixed a real
bug in `GitRepository.run()`: it was throwing `GitError.commandFailed` with `stdout` instead
of `stderr`, so almost every thrown error message was blank (git writes its `fatal:`/`error:`
text to stderr) — this silently broke `push()`'s "no upstream branch yet" detection and made
every error alert in the app uninformative.

### 2b. Manual UI test pass

Some of the above need a human eye against the actual 4-column UI (sidebar drag-reorder,
diff rendering, hunk borders, etc.) — CLAUDE.md's standing rule is build+launch, no
automated screenshots. For beta, do one deliberate pass through this matrix in the running
app rather than only relying on incidental use.

- [ ] Sidebar: reorder repos/folders via drag, rename, delete, custom `.icon` assignment
- [ ] All git states above, walked through in the actual UI
- [ ] Multi-repo, multi-folder sidebar structure with several repos open in sequence

## 3. Destructive-action safety audit

Only two `NSAlert` usages exist in the whole codebase today (`AppState.swift:210`,
`SidebarOutlineView.swift:693`). Before beta, audit every irreversible git action and make
sure each one that can lose uncommitted work has a confirmation:

- [x] Discard changes (single file / all files) — `AppState.discardChanges` now confirms via
      `NSAlert` before calling into git, and calls out untracked files specifically (`git
      clean` deletes them outright, with no commit to fall back to, unlike tracked files)
- [x] Clean untracked / ignored files — same path as "Discard changes": untracked files go
      through `discardChanges`/`git clean -f`, now covered by the same confirmation
- [x] Checkout that overwrites local changes — already had a confirmation
      (`promptForDirtyCheckout`, `AppState.swift`); re-verified as part of this pass, no
      change needed
- [x] Merge abort — `AppState.abortMerge` now confirms before `git merge --abort`
- [ ] Branch delete (especially unmerged branches) — N/A for now: there's no branch-delete
      action anywhere in the UI yet (`BranchListView` is still commit-history-only, per
      CLAUDE.md's "Not yet implemented"). Revisit once branch deletion actually exists.
- [x] Stash drop (once stash actions exist beyond apply) — `AppState.discardStash` now
      confirms before `git stash drop`
- [x] Repo removal from sidebar — should be clear this doesn't touch disk, vs. anything
      that actually deletes files (2026-08-12: relabeled the context-menu item "Remove from
      Sidebar" instead of plain "Remove", and dropped its destructive/red styling — it never
      touches disk, so it didn't belong in the same visual class as the actions above)

## 4. Auto-update: Sparkle

- [x] Add Sparkle via SPM (2026-08-19: added as an `XCRemoteSwiftPackageReference` the same
      way `HighlightSwift` already was, pinned `upToNextMajorVersion` from 2.6.0, resolves to
      2.9.6; confirmed it links and codesigns cleanly — no repeat of the earlier
      SwiftGit2/libgit2 arm64 linking problems, which were specific to that C-library package)
- [x] Generate an EdDSA signing key (2026-08-19: generated via Sparkle's `generate_keys`
      tool, which shipped with the SPM package artifact — no separate install needed. The
      private key lives only in the user's macOS Keychain, never touches disk as a file, and
      isn't in the repo. The public key is wired into the app — see below)
- [x] Decide update feed hosting (2026-08-19): GitHub Releases + `appcast.xml`. The feed file
      lives at the repo root, tracked in git, served via
      `https://raw.githubusercontent.com/garrill/Leaf/main/appcast.xml` — that's now
      `SUFeedURL` in `Leaf/Info.plist`. `appcast.xml` currently has an empty `<channel>` (no
      `<item>`s yet — nothing to point at until a signed, notarized DMG exists, roadmap #5).
      Per-release process once that exists: build the DMG, run Sparkle's `generate_appcast`
      tool against it (signs it using the Keychain-stored EdDSA private key from the item
      above, emits an `<item>` with the enclosure URL + signature), commit the updated
      `appcast.xml` to `main`, then attach the DMG to the matching GitHub Release. This repo
      needs to be public (or the feed URL needs rethinking) for `raw.githubusercontent.com` to
      be reachable by installed copies of the app — not yet confirmed either way here.
- [x] Wire up `SUUpdater`/`SPUStandardUpdaterController`, "Check for Updates…" menu item
      (2026-08-19: `UpdaterHolder` (`Leaf/UpdaterController.swift`) holds the single
      `SPUStandardUpdaterController(startingUpdater: true, ...)`, touched once from
      `AppDelegate.applicationDidFinishLaunching` to force its creation at launch, since
      `LeafApp`'s `.commands` are declared independently of `AppDelegate` (same pattern
      `AppStateHolder` already uses for the Repository menu); "Check for Updates…" lives in
      `CommandGroup(after: .appInfo)` and disables itself via `CheckForUpdatesViewModel`
      (`@Published` mirror of `SPUUpdater.canCheckForUpdates`, Sparkle's own documented
      SwiftUI pattern, since `SPUUpdater` itself isn't `ObservableObject`). `SUPublicEDKey` is
      wired in (2026-08-19) — see the signing-key item above. `SUFeedURL` is now wired too —
      see "Decide update feed hosting" above)
- [ ] Confirm notarization + Sparkle interact correctly (notarized builds, Sparkle's own
      code-signature verification of downloaded updates) — blocked on the paid Apple Developer
      account (needed for a Developer ID Application certificate); see #5
- [x] Decide update cadence/channel (2026-08-19): single channel for now (no separate
      beta/stable feed — not enough release volume yet to justify one). Cadence: Sparkle's
      default `SUScheduledCheckInterval` (daily, 86400s), set explicitly in `Leaf/Info.plist`
      rather than left implicit. Automatic silent installs left off (`SUAutomaticallyUpdate`
      unset → Sparkle's default of downloading and asking before installing), appropriate for
      a beta where surprising auto-installs would be unwelcome — revisit once the app is more
      mature

## 5. Release engineering

`CODE_SIGN_STYLE = Automatic` (Development signing), `DEVELOPMENT_TEAM` set, no entitlements
file. Paid Apple Developer account not active yet — Developer ID signing and notarization stay
blocked on that; everything else in this section is unblocked and done or scripted below.

- [ ] Developer ID Application signing (distinct from the current automatic Development
      signing) for direct distribution — blocked on paid Apple Developer account
- [ ] Notarization pipeline (`notarytool submit` + staple), scripted so it's repeatable —
      blocked on paid Apple Developer account (needs a Developer ID cert + app-specific
      password/keychain profile); `scripts/make_dmg.sh` (below) has a comment marking exactly
      where the `notarytool submit ... --wait` + `stapler staple` steps go once unblocked
- [x] DMG packaging (2026-08-19): `scripts/make_dmg.sh` — builds Release config via
      `xcodebuild -derivedDataPath`, stages the built `.app` + an `/Applications` symlink, and
      runs `hdiutil create -format UDZO`. Produces `build/Leaf-<version>.dmg`, ad-hoc/Development-
      signed only until Developer ID exists (see above). No background image yet — plain
      DMG for now; the roadmap's "cosmetic but expected" background image is still open
- [x] `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` bump process (2026-08-19): bumped the
      placeholder `1.0` → `0.1.0` for beta across all three targets' Debug/Release configs.
      No automated bump tooling yet (e.g. `agvtool`) — manual edit of `project.pbxproj` per
      release for now, revisit if release frequency makes that painful
- [x] CI (2026-08-19): `.github/workflows/ci.yml` — `xcodebuild build` then `xcodebuild test`
      against the `Leaf` scheme on `macos-latest`, with `CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO` so it doesn't need a signing identity. Caveat: this project's
      `objectVersion 77` / macOS 26.5 SDK is newer than any Xcode version confirmed available
      on GitHub-hosted macOS runners at the time this was written — the workflow lists
      installed Xcode versions as a debug step; if the default is too old to open the project,
      pin one with `xcode-select -s` or move to a self-hosted/larger runner. Not yet confirmed
      green on an actual push
- [x] `LICENSE` file (2026-08-19): MIT, user's explicit choice
- [x] `CHANGELOG.md` or release notes convention (2026-08-19): added, `[Unreleased]` +
      per-version sections, with a note that each version's entry doubles as the appcast
      `<description>` when that version ships
- [ ] `README.md` refresh with real screenshots for outside readers (text content is
      renamed to Leaf already; still needs actual screenshots and outward-facing polish)

## 6. Beta-readiness polish

- [x] "Git not installed" / Xcode Command Line Tools missing — already handled:
      `GitRepository.isGitAvailable()` is checked at launch (`MainWindowController.swift`) and
      `GitUnavailableView.swift` shows a dedicated screen with an "Install Command Line Tools"
      button (`xcode-select --install`) and a "Check Again" retry
- [x] First-run / empty-state experience — already handled: `RepoListView.swift` shows "No
      Repositories" / "Add a folder that contains a git repository to get started." with a
      prominent "Add local repository" button when the sidebar is empty
- [x] Consistent error surfacing for failed git operations — git-op errors funnel into
      `AppState.errorMessage`, shown in the always-mounted `DiffView` column; clone/new-branch
      errors get their own sheet-local text. Meaningfully improved by the `GitRepository.run()`
      stderr fix from the test-coverage pass (2026-08-12) — thrown messages used to read stdout
      (usually blank on failure) instead of stderr (where git's actual `fatal:`/`error:` text
      goes)
- [x] Settings/Preferences window completeness pass (2026-08-12): real `Settings` scene
      (`SettingsView.swift`, opens via the standard Cmd+,) with a diff font-size slider (wired
      through `DiffCodeScrollView`/`DiffCodeTextView`/`DiffGutterView`, whose line-number font
      now scales proportionally with it) and a default-external-editor picker (wired into
      "Open in Default Program" in `ChangedFilesView`, via `NSWorkspace.OpenConfiguration`)
- [x] Standard macOS menu bar completeness (2026-08-12): added a `.commands` block in
      `LeafApp.swift` inserting "Leaf Help" and "Report an Issue…" into the Help menu (linking
      to the GitHub repo's README and a new-issue page); Window menu is the standard
      SwiftUI-provided one. About panel version is still whatever `MARKETING_VERSION` says,
      which is still the placeholder `1.0` — tracked separately in #1
- [x] A lightweight in-app "Report an issue" path — same Help-menu item above
      ("Report an Issue…" → `https://github.com/garrill/Leaf/issues/new`)
- [x] Crash visibility — deliberate "no" recorded here: no crash-reporting SDK for this beta;
      relying on the OS's own crash logs (Console.app / `~/Library/Logs/DiagnosticReports`),
      which need no app-side setup
- [x] Privacy note (2026-08-12): added to `README.md` (new "Privacy" section) and to the new
      Settings window's "Privacy" section

## 7. Explicitly deferred (not required for this beta)

- Mac App Store distribution + App Sandbox (see decision note at top)
- Multi-entry stash browsing (already tracked in CLAUDE.md's "Not yet implemented")
- Real 3-way conflict diff view (already tracked)
- Branch-list-as-real-branch-list promotion (already tracked)
- Localization
- Accessibility/VoiceOver pass
