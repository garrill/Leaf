# Leaf — Beta Readiness Roadmap

**Distribution decision (2026-08-12):** ship direct-distribution (notarized DMG, outside
the Mac App Store) with Sparkle for auto-update. App Sandbox stays off — the git backend
keeps shelling out to `/usr/bin/git` unchanged. Mac App Store + sandboxing is a separate
future decision, not required for beta; revisit only if we want MAS distribution later; at
that point expect a real research spike (security-scoped bookmarks per repo, whether a
sandboxed process can still spawn `/usr/bin/git` against arbitrary user-selected paths, and
possibly a libgit2/SwiftGit2 rewrite of `GitRepository`).

---

## 1. Rename: Current → Leaf ✅

## 2. Test coverage ✅

## 3. Destructive-action safety audit ✅

## 4. Auto-update: Sparkle

- [ ] Confirm notarization + Sparkle interact correctly (notarized builds, Sparkle's own
      code-signature verification of downloaded updates) — blocked on the paid Apple Developer
      account (needed for a Developer ID Application certificate); see #5

## 5. Release engineering

`CODE_SIGN_STYLE = Automatic` (Development signing), `DEVELOPMENT_TEAM` set, no entitlements
file. Paid Apple Developer account not active yet — Developer ID signing and notarization stay
blocked on that; everything else in this section is unblocked and done or scripted.

- [ ] Developer ID Application signing (distinct from the current automatic Development
      signing) for direct distribution — blocked on paid Apple Developer account
- [ ] Notarization pipeline (`notarytool submit` + staple), scripted so it's repeatable —
      blocked on paid Apple Developer account (needs a Developer ID cert + app-specific
      password/keychain profile); `scripts/make_dmg.sh` has a comment marking exactly
      where the `notarytool submit ... --wait` + `stapler staple` steps go once unblocked
- [ ] `README.md` refresh with real screenshots for outside readers (text content is
      renamed to Leaf already; still needs actual screenshots and outward-facing polish)

## 6. Beta-readiness polish ✅

## 7. Post-beta feature & polish backlog

Newly gathered list (2026-08-24), not yet started. Grouped where a few small items share
one underlying change; expanded where a single line hides real design/implementation
decisions.

### Navigation & interaction

- [x] **Cross-column keyboard navigation.** Left/right arrow keys move focus between all
      four columns (sidebar → branches/history → changed files → diff), via
      `AppState.focusedColumn` (a shared `MainColumn?`) that each hosting controller's root
      view reads/writes, syncing its own local `@FocusState`/AppKit first-responder status
      against it. The diff column claims real first-responder status on its underlying
      `NSTextView` rather than a synthetic SwiftUI focus proxy, so up/down, page up/down,
      home/end, etc. all come from `NSTextView`'s native key bindings instead of being
      hand-rolled.
- [x] **Commit box shortcuts:** Enter/Return triggers the Commit button (commit only, no
      push) without requiring a mouse click; Escape undoes a commit.

### Diff viewer

- [ ] **Restyle syntax highlighting.** Current `HighlightSwift`/highlight.js theme is
      generic — look at how Fork, Tower, GitHub Desktop, and Changes.app style diff syntax
      (color choices, weight/contrast against the added/removed row backgrounds, how muted
      vs. vivid they keep it) and bring the palette closer to one of those references
      rather than a stock highlight.js theme.
- [ ] **Hide whitespace-only changes.** Toggle (Settings, or a button directly on the diff
      pane toolbar — pick whichever fits the existing diff-pane chrome better) to view a
      diff with whitespace-only changes suppressed, likely `git diff -w`/`--ignore-all-space`
      under the hood.
- [ ] Reconsider the icon shown at the top of the diff viewer — possibly remove it
      entirely; revisit once the syntax-highlighting restyle above has landed, since that
      may change what the diff pane's header area needs to hold.

### Chrome / window polish

- [ ] **Progressive blur behind the traffic lights while scrolling.** Content scrolling
      under the titlebar today has no blur effect — CLAUDE.md already notes the soft
      scroll-edge blur (`.safeAreaBar` + `.scrollEdgeEffectStyle(.soft, for: .top)`) only
      renders against a column's own `safeAreaBar`, and that a prior pure-SwiftUI attempt
      to layer content under the titlebar via `.ignoresSafeArea(.top)` rendered but ate
      clicks. Needs its own investigation into whether the working `safeAreaBar` approach
      used elsewhere in the app can be extended up to the titlebar/traffic-light area, or
      whether this needs an AppKit-level titlebar accessory view instead.
- [ ] **Default repo icon.** Either let the user pick a custom icon per repo (there's
      already an `IconComposerRenderer`-based sidebar glyph system per CLAUDE.md — a picker
      would hang off that), or, if a picker is more than this deserves right now, just
      improve the current default glyph. Which of the two — ask me once you're looking at
      the existing icon code, I'm not sure yet which is worth the effort.

### History / commits

- [x] **Tags.** Show git tags in the history/branch column (alongside commits, similar to
      how branch labels are likely already shown), and support right-clicking a commit to
      create a tag there (e.g. for marking a release). Needs both a `GitRepository`-level
      read (`git tag --list` w/ the commit each points at) and write ( `git tag <name>
      <commit>` ) path, plus a bit of UI in `BranchListView`'s context menu.
- [ ] **Expand a truncated commit title.** When a commit is selected, in the
      top title bar area there should be a button to extend the title so it can go over 
      multiple lines

### Bugs

- [x] **"No changes" message shown incorrectly after committing.** After a commit
      completes, the changed-files shows a "no changes" empty state  rather than the files
      that have just been commited. Reproduce against `AppState`'s post-commit reload path
      (`loadChangedFilesForCurrentSelection`) before fixing.
- [x] **Discard changes should move the file to the Trash, not delete it outright.**
      `GitRepository.discardChanges(for:)` now moves each affected path's current on-disk
      contents to the Trash (`FileManager.trashItem`) before running the actual discard —
      `git checkout --` for tracked files, nothing further for untracked (trashing the file
      *is* the discard, replacing the old `git clean -f`). Applies uniformly to both tracked
      and untracked paths, so any accidental discard is recoverable from the Trash.

## 8. Explicitly deferred (not required for this beta)

- Mac App Store distribution + App Sandbox (see decision note at top)
- Multi-entry stash browsing (already tracked in CLAUDE.md's "Not yet implemented")
- Real 3-way conflict diff view (already tracked)
- Branch-list-as-real-branch-list promotion (already tracked)
- Localization
- Accessibility/VoiceOver pass
