#!/usr/bin/env bash
# Makes and publishes a release: build/Moria-<version>.dmg, signed with Developer ID, notarized
# and stapled; the version bumped and the changelog dated, committed and tagged; then pushed and
# published as a GitHub release with the Sparkle feed (appcast.xml) that installed copies read.
#
#   Scripts/release.sh 0.2.0
#   DRY_RUN=1 Scripts/release.sh 0.2.0   # build the disk image and the feed; no notarization,
#                                        # commit, tag or publishing, and the version files
#                                        # are put back
#
# Needs, once:
#   - a "Developer ID Application" signing identity (or SIGN_IDENTITY naming one)
#   - notarization credentials in the keychain, stored with
#       xcrun notarytool store-credentials moria --apple-id <id> --team-id <team>
#     (NOTARY_PROFILE names another profile)
#   - the update signing key in the keychain (see Scripts/release.env)
#   - gh signed in with push access to the repository
#
# The release notes are the changelog's "Unreleased" section.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: Scripts/release.sh <version>, e.g. 0.2.0}
NOTARY_PROFILE=${NOTARY_PROFILE:-moria}
DRY_RUN=${DRY_RUN:-0}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3, got $VERSION" >&2; exit 1; }
source version.env
source Scripts/release.env
LAST=$(git tag --list 'v*' --sort=-v:refname | head -1)
LAST=${LAST#v}
if [[ -n "$LAST" && ( "$(printf '%s\n%s\n' "$LAST" "$VERSION" | sort -V | tail -1)" != "$VERSION" || "$VERSION" == "$LAST" ) ]]; then
  echo "Version $VERSION must be newer than the last release, $LAST" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash changes first: the release is built from what is committed." >&2
  exit 1
fi
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
[[ "$IDENTITY" == "Developer ID Application:"* ]] || { echo "No Developer ID Application identity; set SIGN_IDENTITY." >&2; exit 1; }
if [[ "$DRY_RUN" != 1 ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarization credentials in keychain profile \"$NOTARY_PROFILE\". Store them with:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id <team id>" >&2
    exit 1
  fi
  gh auth status >/dev/null 2>&1 || { echo "gh isn't signed in; run gh auth login." >&2; exit 1; }
  [[ "$(git branch --show-current)" == main ]] || { echo "Release from main." >&2; exit 1; }
fi

# Sparkle's release tools.
CACHE=build/cache
TOOLS="$CACHE/sparkle-$SPARKLE_VERSION"
if [[ ! -x "$TOOLS/bin/generate_appcast" ]]; then
  mkdir -p "$CACHE"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$CACHE/sparkle.tar.xz"
  echo "$SPARKLE_SHA256  $CACHE/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
  rm -rf "$TOOLS" && mkdir -p "$TOOLS"
  tar -xJf "$CACHE/sparkle.tar.xz" -C "$TOOLS"
  rm "$CACHE/sparkle.tar.xz"
fi

# Version and changelog. Put back if anything below fails (and always on a dry run), so a
# failed release leaves the tree as it was.
restore() { git checkout -- version.env CHANGELOG.md; }
trap 'status=$?; [[ $status != 0 ]] && restore; exit $status' EXIT
BUILD=$((BUILD_NUMBER + 1))
printf 'MARKETING_VERSION=%s\nBUILD_NUMBER=%s\n' "$VERSION" "$BUILD" > version.env
grep -q '^## Unreleased' CHANGELOG.md || { echo "CHANGELOG.md has no \"## Unreleased\" section" >&2; exit 1; }
sed -i '' "s/^## Unreleased\$/## Unreleased\\
\\
## $VERSION — $(date +%Y-%m-%d)/" CHANGELOG.md

swift test
SIGN_IDENTITY="$IDENTITY" Scripts/package_app.sh

APP=build/Moria.app
DMG=build/Moria-$VERSION.dmg
notarize() {
  echo "Notarizing $(basename "$1")…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 1h | tee build/notary.log
  # `submit --wait` exits 0 even when Apple rejects the file.
  grep -q "status: Accepted" build/notary.log || {
    id=$(awk '/^  id:/ {print $2; exit}' build/notary.log)
    echo "Notarization failed; details: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  }
}

# The app is notarized and stapled on its own too, so it opens without a network check after
# it is copied out of the disk image.
if [[ "$DRY_RUN" != 1 ]]; then
  ditto -c -k --keepParent "$APP" build/Moria.zip
  notarize build/Moria.zip
  rm build/Moria.zip
  xcrun stapler staple "$APP"
fi

# Disk image: the app and a link to Applications, to drag it onto.
STAGING=build/dmg
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Moria.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Moria $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" -quiet
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [[ "$DRY_RUN" != 1 ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type execute "$APP"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi

# The Sparkle feed: the published one with this release added, signed with the update key.
# Release notes are this version's changelog section.
FEED=build/release
rm -rf "$FEED" && mkdir -p "$FEED"
# A failed lookup stops the release: going on without the published feed would drop the
# earlier versions from it.
RELEASES=$(gh release list --repo "$GITHUB_REPO" --limit 1 --json tagName --jq length)
if [[ "$RELEASES" != 0 ]]; then
  curl -fsSL "https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml" -o "$FEED/appcast.xml"
fi
cp "$DMG" "$FEED/"
awk -v heading="## $VERSION " 'index($0, heading) == 1 { found = 1; next } found && /^## / { exit } found' CHANGELOG.md \
  | sed '/./,$!d' > "$FEED/Moria-$VERSION.md"
[[ -s "$FEED/Moria-$VERSION.md" ]] || { echo "The changelog's Unreleased section is empty: nothing to say about $VERSION." >&2; exit 1; }
"$TOOLS/bin/generate_appcast" --account "$SPARKLE_KEY_ACCOUNT" --embed-release-notes \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$GITHUB_REPO" "$FEED"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$FEED/appcast.xml" || { echo "appcast.xml has no entry for build $BUILD" >&2; exit 1; }

if [[ "$DRY_RUN" == 1 ]]; then
  codesign --verify --strict "$DMG"
  restore
  echo "Dry run: built $DMG ($VERSION build $BUILD), signed but not notarized, and $FEED/appcast.xml. version.env and CHANGELOG.md are unchanged."
  exit 0
fi

git add version.env CHANGELOG.md
git commit -q -m "chore: release $VERSION"
git tag -a "v$VERSION" -m "Moria $VERSION"
trap - EXIT
git push origin main "v$VERSION"
gh release create "v$VERSION" "$DMG" "$FEED/appcast.xml" --repo "$GITHUB_REPO" --verify-tag \
  --title "Moria $VERSION" --notes-file "$FEED/Moria-$VERSION.md"
echo "Released Moria $VERSION (build $BUILD): https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
