#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="release/macos/arm64"
work="artifacts/macos/package"
mkdir -p "$output" "$work"
xcodebuild archive -project macos/DynamicPhotoWall.xcodeproj -scheme DynamicPhotoWall \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$work/DerivedData" -archivePath "$work/DynamicPhotoWall.xcarchive" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES 2>&1 | tee "$work/archive.log"
app="$work/DynamicPhotoWall.xcarchive/Products/Applications/DynamicPhotoWall.app"
[[ "$(lipo -archs "$app/Contents/MacOS/DynamicPhotoWall")" == "arm64" ]]
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$app/Contents/Info.plist")" == "true" ]]
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/DynamicPhotoWall-macos-arm64.zip"
# Keep the /Applications link outside the workspace so editor searches cannot
# follow it into installed apps. Remove staging even when DMG creation fails.
staging=$(mktemp -d "${TMPDIR:-/tmp}/dynamic-photo-wall-dmg.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
ditto "$app" "$staging/DynamicPhotoWall.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Dynamic Photo Wall" -srcfolder "$staging" -ov -format UDZO \
    "$output/DynamicPhotoWall-macos-arm64.dmg"
pushd "$output" >/dev/null
shasum -a 256 DynamicPhotoWall-macos-arm64.zip DynamicPhotoWall-macos-arm64.dmg > SHA256SUMS
popd >/dev/null
echo "Local ad-hoc candidate: $output (ZIP/DMG; not published; not notarized)"
