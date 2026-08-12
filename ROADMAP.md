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

- [ ] Add Sparkle via SPM (unrelated to the earlier SwiftGit2/libgit2 linking problems
      noted in CLAUDE.md — those were about a C-library package failing to link for macOS
      arm64 specifically; Sparkle ships a standard prebuilt XCFramework and is widely used
      via SPM on macOS, but confirm it links cleanly in this project early rather than
      assuming)
- [ ] Generate an EdDSA signing key (`generate_keys` tool from Sparkle), keep the private
      key out of the repo
- [ ] Decide update feed hosting — GitHub Releases + a generated `appcast.xml` is the
      standard low-effort option and pairs naturally with notarized DMG releases
- [ ] Wire up `SUUpdater`/`SPUStandardUpdaterController`, "Check for Updates…" menu item
- [ ] Confirm notarization + Sparkle interact correctly (notarized builds, Sparkle's own
      code-signature verification of downloaded updates)
- [ ] Decide update cadence/channel (e.g. beta channel vs stable, if this beta will get
      frequent point releases)

## 5. Release engineering

Currently `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM` set, no entitlements file, no
CI config, no LICENSE.

- [ ] Developer ID Application signing (distinct from the current automatic Development
      signing) for direct distribution
- [ ] Notarization pipeline (`notarytool submit` + staple), scripted so it's repeatable
- [ ] DMG packaging (background image, Applications symlink — cosmetic but expected)
- [ ] `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` bump process tied to releases
- [ ] CI (GitHub Actions or similar) running build + the new test target on every push —
      currently no `.yml` workflow exists at all
- [ ] `LICENSE` file (none currently present — decide terms before any public release)
- [ ] `CHANGELOG.md` or release notes convention (feeds the Sparkle appcast description)
- [ ] `README.md` refresh with real screenshots for outside readers (text content is
      renamed to Leaf already; still needs actual screenshots and outward-facing polish)

## 6. Beta-readiness polish

- [ ] "Git not installed" / Xcode Command Line Tools missing — currently unhandled;
      `GitRepository` shells to `/usr/bin/git` and will presumably fail confusingly rather
      than explain what's wrong
- [ ] First-run / empty-state experience: what a brand-new user sees before adding any
      repo — confirm it's a clear "Add a repository" prompt, not a blank pane
- [ ] Consistent error surfacing for failed git operations (network errors, auth failures,
      permission errors) — audit whether failures currently fail silently vs. show
      something actionable
- [ ] Settings/Preferences window completeness pass (whatever currently exists in
      `CurrentApp.swift`/`AppDelegate.swift`) — anything beta users would expect to
      configure (diff font size, default external editor, etc.)
- [ ] Standard macOS menu bar completeness (Window menu, Help menu with a feedback/issue
      link, About panel with correct version)
- [ ] A lightweight in-app "Report an issue" path (mailto: or link to a GitHub issues
      page) so beta feedback has a channel
- [ ] Crash visibility — at minimum confirm crash logs are locatable in Console.app /
      `~/Library/Logs/DiagnosticReports`; a crash-reporting SDK is likely overkill for an
      initial beta but worth a deliberate "no" rather than an oversight
- [ ] Privacy note: the app is local-only and shells out to the user's own git — worth a
      one-line statement (README or in-app) since there's no telemetry to disclose, but
      beta users will ask

## 7. Explicitly deferred (not required for this beta)

- Mac App Store distribution + App Sandbox (see decision note at top)
- Multi-entry stash browsing (already tracked in CLAUDE.md's "Not yet implemented")
- Real 3-way conflict diff view (already tracked)
- Branch-list-as-real-branch-list promotion (already tracked)
- Localization
- Accessibility/VoiceOver pass
