#!/usr/bin/env bash
# Publish a StitchPeek release that installed copies will pick up and install themselves.
#
#     Scripts/release.sh 1.2.0 [notes.md]
#
# Bumps VERSION, regenerates the project, runs the tests, does a clean Release build,
# zips and signs it, tags, pushes, publishes the GitHub release, then downloads the assets
# back and verifies them exactly as the app will. Refuses to run on a dirty tree, off main,
# for a version that isn't newer, or with a signing key that doesn't match the app's.
#
# Without a notes file, the notes are the commit subjects since the last release.
set -euo pipefail

VERSION="${1:-}"
NOTES_FILE="${2:-}"
REPO="bobbymarko/StitchPeek"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

die() { echo "release: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: release.sh X.Y.Z [notes.md]"
# Snapshot the notes now: the clean build below deletes build/, where notes often live.
if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || die "no notes file at $NOTES_FILE"
  SNAPSHOT=$(mktemp)
  cp "$NOTES_FILE" "$SNAPSHOT"
  NOTES_FILE="$SNAPSHOT"
fi
cd "$ROOT"

step "Preflight"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit first"
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not in sync with origin/main"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "tag v$VERSION already exists"

LATEST=$(gh release view -R "$REPO" --json tagName --jq .tagName 2>/dev/null | sed 's/^v//' || true)
if [ -n "$LATEST" ]; then
  NEWEST=$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  [ "$NEWEST" = "$VERSION" ] && [ "$LATEST" != "$VERSION" ] || die "$VERSION is not newer than the latest release ($LATEST)"
fi

APP_KEY=$(sed -n 's/.*static let publicKey = "\(.*\)".*/\1/p' StitchPeek/Updater.swift)
SIGN_KEY=$(swift Scripts/sign_update.swift public-key) || die "no signing key — see Scripts/sign_update.swift"
[ "$APP_KEY" = "$SIGN_KEY" ] || die "signing key doesn't match the public key compiled into Updater.swift"
echo "version $VERSION (latest published: ${LATEST:-none}); signing key matches the app"

step "Version"
echo "$VERSION" > VERSION
python3 Scripts/generate_project.py >/dev/null

step "Tests"
swift test --package-path Packages/StitchKit 2>&1 | tail -1

step "Clean Release build"
rm -rf build
xcodebuild -project StitchPeek.xcodeproj -scheme StitchPeek -configuration Release \
  -derivedDataPath build build 2>&1 | grep -E "error:|\*\* BUILD" | sort -u
APP="build/Build/Products/Release/StitchPeek.app"
[ -d "$APP" ] || die "build produced no app"
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$BUILT" = "$VERSION" ] || die "built app says $BUILT, expected $VERSION"
codesign --verify --deep --strict "$APP"

step "Archive and sign"
mkdir -p "$OUT"
rm -f "$OUT/StitchPeek.zip" "$OUT/StitchPeek.zip.sig"
# ditto, not zip: keeps the bundle's symlinks and code signature intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/StitchPeek.zip"
swift Scripts/sign_update.swift sign "$OUT/StitchPeek.zip" > "$OUT/StitchPeek.zip.sig"
swift Scripts/sign_update.swift verify "$OUT/StitchPeek.zip" "$OUT/StitchPeek.zip.sig" "$APP_KEY"

step "Tag and push"
if [ -n "$(git status --porcelain)" ]; then
  git add VERSION StitchPeek.xcodeproj/project.pbxproj
  git commit -q -m "Release $VERSION"
fi
git tag -a "v$VERSION" -m "StitchPeek $VERSION"
git push -q origin main "v$VERSION"

step "Publish"
if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE="$OUT/notes.md"
  {
    echo "## Changes"
    echo
    if [ -n "$LATEST" ]; then
      git log --pretty='- %s' "v$LATEST..HEAD" | grep -v "^- Release $VERSION$" || true
    else
      git log --pretty='- %s' | grep -v "^- Release $VERSION$" || true
    fi
    echo
    echo "Installed copies update themselves from the banner or *StitchPeek → Check for Updates…*."
  } > "$NOTES_FILE"
fi
gh release create "v$VERSION" -R "$REPO" --title "StitchPeek $VERSION" --notes-file "$NOTES_FILE" \
  "$OUT/StitchPeek.zip" "$OUT/StitchPeek.zip.sig"

step "Verify what was published, the way the app will"
CHECK=$(mktemp -d)
gh release download "v$VERSION" -R "$REPO" --dir "$CHECK"
swift Scripts/sign_update.swift verify "$CHECK/StitchPeek.zip" "$CHECK/StitchPeek.zip.sig" "$APP_KEY"
ditto -x -k "$CHECK/StitchPeek.zip" "$CHECK/unpacked"
codesign --verify --deep --strict "$CHECK/unpacked/StitchPeek.app"
PUBLISHED=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CHECK/unpacked/StitchPeek.app/Contents/Info.plist")
[ "$PUBLISHED" = "$VERSION" ] || die "published app says $PUBLISHED"
LIVE=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
[ "$LIVE" = "v$VERSION" ] || die "releases/latest is $LIVE, not v$VERSION — the app won't see this release"
rm -rf "$CHECK"

echo
echo "Released $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
echo "Installed copies will offer it at next launch, or within six hours."
