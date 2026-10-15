#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="artifacts/macos-release/candidate"
mkdir -p "$output"
xcodebuild archive -project macos/DynamicPhotoWall.xcodeproj -scheme DynamicPhotoWall \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$output/DerivedData" -archivePath "$output/DynamicPhotoWall.xcarchive" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES 2>&1 | tee "$output/archive.log"
app="$output/DynamicPhotoWall.xcarchive/Products/Applications/DynamicPhotoWall.app"
[[ "$(lipo -archs "$app/Contents/MacOS/DynamicPhotoWall")" == "arm64" ]]
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$app/Contents/Info.plist")" == "true" ]]
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/DynamicPhotoWall-macos-arm64.zip"
staging=$(mktemp -d "$output/dmg-staging.XXXXXX")
ditto "$app" "$staging/DynamicPhotoWall.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Dynamic Photo Wall" -srcfolder "$staging" -ov -format UDZO     "$output/DynamicPhotoWall-macos-arm64.dmg"
pushd "$output" >/dev/null
shasum -a 256 DynamicPhotoWall-macos-arm64.zip DynamicPhotoWall-macos-arm64.dmg > SHA256SUMS
popd >/dev/null
echo "Local ad-hoc candidate: $output (ZIP/DMG; not published; not notarized)"
