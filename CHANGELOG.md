# Changelog

All notable changes to Leaf are documented here. Entries are grouped by release version
and follow [Keep a Changelog](https://keepachangelog.com/) conventions loosely.

Each entry here should also become the `<description>` (release notes) of the matching
`<item>` in `appcast.xml` when that version ships.

## [0.3.0]

* Keyboard navigation: ← / → move left and right columns. Diff viewer is scrollable by keyboard. You can press ⏎ Enter to submit a commit. ␛ Escape undoes a commit.
* Tags: Add / remove and view tags on a commit.
* Discarding changes on a file now move that file to the Trash so it can be retrieved if needed.
* Success toast: uses `.glassEffect` rather than trying to reproduce it.
* Image comparison: images are correctly masked.
* Optimisation: cleaned up concurrency & deprecation warnings.

## [0.2.0]

* Sidebar updates: 'Add repo to group' option, 'Remove and delete repo' option
* Feedback: push to origin shows progress and success message, clone repo shows progress bar
* Error handling: show alerts for push failures

## [0.1.0] - Unreleased

First beta. See ROADMAP.md for what's still outstanding before this ships.


