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

- [ ] Restyle syntax highlighting.
- [ ] Allow user to pick default repo icon (in settings)
- [ ] **Better Settings window: organise into tabs.** Current Settings window is a single
flat pane; split it into tabbed sections (the standard macOS `TabView`-backed
Settings pattern — e.g. General, Diff/Appearance, Git, Advanced/Updates) so options
are grouped logically as more of them accumulate, rather than one long list.

## 8. Explicitly deferred (not required for this beta)

- Mac App Store distribution + App Sandbox (see decision note at top)
- Multi-entry stash browsing (already tracked in CLAUDE.md's "Not yet implemented")
- Real 3-way conflict diff view (already tracked)
- Localization
- Accessibility/VoiceOver pass
