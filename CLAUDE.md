# StitchPeek — notes for agents

macOS viewer + Quick Look extensions for Tajima DST embroidery files. Installed on two Macs
(Bobby's and Maura's); both update themselves from GitHub Releases. Read README.md for the
architecture and for the platform gotchas that already cost time — don't rediscover them.

## Feedback queue

People file feedback from inside the app (Help → Send Feedback, ⇧⌘F, or the speech-bubble
toolbar button). Each report becomes an issue in the **private** repo
`bobbymarko/StitchPeek-feedback`, labelled `feedback` plus `bug` or `enhancement`, with:

- their comment (first line is the title);
- a screenshot of the window, often with **numbered red markers** on the spots they mean;
- a context table: who/which Mac, app version, macOS, which screen, the design and its stats,
  zoom / isolated block / scrubber / recolors;
- sometimes the `.dst` itself, attached.

```bash
python3 Scripts/feedback.py list          # open feedback
python3 Scripts/feedback.py show 12       # full report; downloads attachments to /tmp/stitchpeek-feedback/12/
```

**Always Read the downloaded screenshot** — the markers carry meaning the text often doesn't.
Check the reported app version first; it may already be fixed in a later release.

Working an item: reproduce (the attached `.dst`, or a fixture in
`Packages/StitchKit/Tests/StitchKitTests/Fixtures`), fix, add a test where the bug is in
StitchKit, release (below), then comment on the issue "Fixed in X.Y.Z — <one line>" and close it.

**Privacy:** feedback names clients and kids, and screenshots show their designs. This repo
is public. Never copy client names, design files, or screenshots from feedback into commits,
fixtures, the README, or release notes — describe the bug generically.

## Build and test

`xcode-select` points at the Command Line Tools, so always:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path Packages/StitchKit
xcodebuild -project StitchPeek.xcodeproj -scheme StitchPeek -configuration Release -derivedDataPath build build
```

The Xcode project is **generated** — add or remove source files in
`Scripts/generate_project.py`, then `python3 Scripts/generate_project.py`. Don't edit
`project.pbxproj` by hand. The version lives in `VERSION` only.

## Releasing

```bash
Scripts/release.sh 1.2.0              # notes = commit subjects since the last release
Scripts/release.sh 1.2.0 notes.md     # or hand-written notes
```

It refuses a dirty tree, a version that isn't newer, or a signing key that doesn't match the
app; then bumps, tests, builds clean, signs, tags, pushes, publishes, and verifies the
published assets the way the app will. Installed copies offer the update at next launch or
within six hours.

- The Ed25519 signing key is at `~/.config/stitchpeek/update-signing-key`. Never commit it,
  print it, or move it. Its public half is compiled into `StitchPeek/Updater.swift`.
- A release without `StitchPeek.zip.sig` can't be installed by the app — always use the script.
- The host app is unsandboxed on purpose (it replaces itself); the Quick Look extensions
  stay sandboxed. Don't "fix" either.
