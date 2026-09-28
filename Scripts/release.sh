#!/usr/bin/env bash
# Builds a release: build/Moria-<version>.dmg, signed with Developer ID, notarized and stapled,
# with the version bumped, the changelog dated, and a commit and tag for it.
#
#   Scripts/release.sh 0.2.0
#   DRY_RUN=1 Scripts/release.sh 0.2.0   # build and sign the disk image; no notarization,
#                                        # commit or tag, and the version files are put back
#
# Needs, once:
#   - a "Developer ID Application" signing identity (or SIGN_IDENTITY naming one)
#   - notarization credentials in the keychain, stored with
#       xcrun notarytool store-credentials moria --apple-id <id> --team-id <team>
#     (NOTARY_PROFILE names another profile)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: Scripts/release.sh <version>, e.g. 0.2.0}
NOTARY_PROFILE=${NOTARY_PROFILE:-moria}
DRY_RUN=${DRY_RUN:-0}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3, got $VERSION" >&2; exit 1; }
source version.env
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
if [[ "$DRY_RUN" != 1 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "No notarization credentials in keychain profile \"$NOTARY_PROFILE\". Store them with:" >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id <team id>" >&2
  exit 1
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

if [[ "$DRY_RUN" == 1 ]]; then
  codesign --verify --strict "$DMG"
  restore
  echo "Dry run: built $DMG ($VERSION build $BUILD), signed but not notarized. version.env and CHANGELOG.md are unchanged."
  exit 0
fi

notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type execute "$APP"
spctl --assess --type open --context context:primary-signature "$DMG"

git add version.env CHANGELOG.md
git commit -q -m "chore: release $VERSION"
git tag -a "v$VERSION" -m "Moria $VERSION"
trap - EXIT
echo "Released $DMG ($VERSION build $BUILD), notarized and stapled; committed and tagged v$VERSION (not pushed)."
