#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="release/macos/arm64"
work="artifacts/macos/package"
mkdir -p "$output" "$work"
candidate=$(mktemp -d "$PWD/$work/candidate.XXXXXX")
staging=""
cleanup() {
    rm -rf -- "$candidate"
    if [[ -n "$staging" ]]; then rm -rf -- "$staging"; fi
}
trap cleanup EXIT
xcodebuild archive -project macos/DynamicPhotoWall.xcodeproj -scheme DynamicPhotoWall \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$work/DerivedData" -archivePath "$work/DynamicPhotoWall.xcarchive" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES 2>&1 | tee "$work/archive.log"
app="$work/DynamicPhotoWall.xcarchive/Products/Applications/DynamicPhotoWall.app"
[[ "$(lipo -archs "$app/Contents/MacOS/DynamicPhotoWall")" == "arm64" ]]
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$app/Contents/Info.plist")" == "true" ]]
# Build all deliverables from the same freshly copied bundle before replacing
# the current local release. ditto into an existing app can leave stale files.
ditto "$app" "$candidate/DynamicPhotoWall.app"
codesign --verify --deep --strict "$candidate/DynamicPhotoWall.app"
ditto -c -k --sequesterRsrc --keepParent "$candidate/DynamicPhotoWall.app" "$candidate/DynamicPhotoWall-macos-arm64.zip"
unzip -tq "$candidate/DynamicPhotoWall-macos-arm64.zip"
# Keep the /Applications link outside the workspace so editor searches cannot
# follow it into installed apps. Remove staging even when DMG creation fails.
staging=$(mktemp -d "${TMPDIR:-/tmp}/dynamic-photo-wall-dmg.XXXXXX")
ditto "$candidate/DynamicPhotoWall.app" "$staging/DynamicPhotoWall.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Dynamic Photo Wall" -srcfolder "$staging" -ov -format UDZO \
    "$candidate/DynamicPhotoWall-macos-arm64.dmg"
hdiutil verify "$candidate/DynamicPhotoWall-macos-arm64.dmg"
pushd "$candidate" >/dev/null
shasum -a 256 DynamicPhotoWall-macos-arm64.zip DynamicPhotoWall-macos-arm64.dmg > SHA256SUMS
shasum -a 256 -c SHA256SUMS
popd >/dev/null
previous=$(mktemp -d "$work/previous-release.XXXXXX")
for name in DynamicPhotoWall.app DynamicPhotoWall-macos-arm64.zip DynamicPhotoWall-macos-arm64.dmg SHA256SUMS; do
    if [[ -e "$output/$name" || -L "$output/$name" ]]; then mv "$output/$name" "$previous/$name"; fi
    mv "$candidate/$name" "$output/$name"
done
echo "Local ad-hoc candidate: $output (APP/ZIP/DMG; not published; not notarized)"
echo "Previous local release: $previous"
