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

## 4. Auto-update: Sparkle ✅

Confirmed 2026-08-26: notarized builds + Sparkle's own code-signature verification of
downloaded updates work end to end — v0.4.0 was released this way and Sparkle pulled and
installed it as an in-app update on the developer's own machine.

## 5. Release engineering ✅

## 6. Beta-readiness polish ✅

## 7. Post-beta feature & polish backlog

- [ ] Restyle syntax highlighting.
- [ ] Allow user to pick default repo icon (in settings)
- [ ] **Better Settings window: organise into tabs.** Current Settings window is a single
flat pane; split it into tabbed sections (the standard macOS `TabView`-backed
Settings pattern — e.g. General, Diff/Appearance, Git, Advanced/Updates) so options
are grouped logically as more of them accumulate, rather than one long list.
- [ ] allow adding descriptions to commits
- [ ] allow viewing of descriptions
- [ ] style mark resolved button
- [ ] expanding title shifts by 2px
- [ ] pick a tag or write new tag
- [x] If changes are made to files, 'no uncommitted changes' doesn't switch over to 'uncommitted changes'
- [x] Fix git bugs and error messages showing for a split second. Trying to push when there are changes upstream. sometimes an untracked file gets in the list. sometimes currently selected file gets out of sync with what is displayed in diff checker.

## 8. Explicitly deferred (not required for this beta)

- Mac App Store distribution + App Sandbox (see decision note at top)
- Multi-entry stash browsing (already tracked in CLAUDE.md's "Not yet implemented")
- Real 3-way conflict diff view (already tracked)
- Localization
- Accessibility/VoiceOver pass
