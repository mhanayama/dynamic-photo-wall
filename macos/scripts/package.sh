#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="release/macos/arm64"
work="artifacts/macos/package"
mkdir -p "$output" "$work"
reuse_app=false
case "${1:-}" in
    "")
        [[ $# -eq 0 ]] || { echo "Usage: $0 [--reuse-app <source-commit>]" >&2; exit 2; }
        source_commit=$(git rev-parse HEAD)
        ;;
    --reuse-app)
        [[ $# -eq 2 ]] || { echo "Usage: $0 [--reuse-app <source-commit>]" >&2; exit 2; }
        reuse_app=true
        source_commit=$(git rev-parse --verify "${2}^{commit}")
        # Reuse only when the declared app sources match the checkout exactly.
        git diff --exit-code "$source_commit" -- macos/DynamicPhotoWall macos/DynamicPhotoWall.xcodeproj
        [[ -z "$(git status --porcelain -- macos/DynamicPhotoWall macos/DynamicPhotoWall.xcodeproj)" ]] || {
            echo "App sources have uncommitted changes; build a new app instead." >&2; exit 1;
        }
        ;;
    *) echo "Usage: $0 [--reuse-app <source-commit>]" >&2; exit 2 ;;
esac
candidate=$(mktemp -d "$PWD/$work/candidate.XXXXXX")
staging=""
cleanup() {
    rm -rf -- "$candidate"
    if [[ -n "$staging" ]]; then rm -rf -- "$staging"; fi
}
trap cleanup EXIT
if "$reuse_app"; then
    app="$output/DynamicPhotoWall.app"
else
    xcodebuild archive -project macos/DynamicPhotoWall.xcodeproj -scheme DynamicPhotoWall \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$work/DerivedData" -archivePath "$work/DynamicPhotoWall.xcarchive" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
        CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES 2>&1 | tee "$work/archive.log"
    app="$work/DynamicPhotoWall.xcarchive/Products/Applications/DynamicPhotoWall.app"
fi
[[ "$(lipo -archs "$app/Contents/MacOS/DynamicPhotoWall")" == "arm64" ]]
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$app/Contents/Info.plist")" == "true" ]]
# Build all deliverables from the same freshly copied bundle before replacing
# the current local release. ditto into an existing app can leave stale files.
ditto "$app" "$candidate/DynamicPhotoWall.app"
codesign --verify --deep --strict "$candidate/DynamicPhotoWall.app"
# Keep documentation outside the sealed bundle, matching Windows packaging.
cp macos/DISTRIBUTION.md "$candidate/README.md"
cp LICENSE THIRD-PARTY-NOTICES.md "$candidate/"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
binary_sha=$(shasum -a 256 "$app/Contents/MacOS/DynamicPhotoWall" | awk '{print $1}')
source_state=clean
if [[ -n "$(git status --porcelain -- macos/DynamicPhotoWall macos/DynamicPhotoWall.xcodeproj)" ]]; then source_state=modified; fi
cat > "$candidate/BUILD-INFO.txt" <<EOF
Dynamic Photo Wall for Mac
Version: $version (build $build)
Source commit: $source_commit
Source URL: https://github.com/mhanayama/dynamic-photo-wall/commit/$source_commit
App source working tree: $source_state
Packaged at (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Architecture: arm64
Minimum macOS: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
Signing: ad-hoc; not notarized
Executable SHA-256: $binary_sha
App reused without rebuilding: $reuse_app
License: MIT (see LICENSE and THIRD-PARTY-NOTICES.md)
EOF
ditto -c -k --sequesterRsrc --keepParent "$candidate/DynamicPhotoWall.app" "$candidate/DynamicPhotoWall-macos-arm64.zip"
extras=(README.md BUILD-INFO.txt LICENSE THIRD-PARTY-NOTICES.md)
for name in "${extras[@]}"; do zip -j "$candidate/DynamicPhotoWall-macos-arm64.zip" "$candidate/$name"; done
unzip -tq "$candidate/DynamicPhotoWall-macos-arm64.zip"
# Keep the /Applications link outside the workspace so editor searches cannot
# follow it into installed apps. Remove staging even when DMG creation fails.
staging=$(mktemp -d "${TMPDIR:-/tmp}/dynamic-photo-wall-dmg.XXXXXX")
ditto "$candidate/DynamicPhotoWall.app" "$staging/DynamicPhotoWall.app"
for name in "${extras[@]}"; do cp "$candidate/$name" "$staging/"; done
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Dynamic Photo Wall" -srcfolder "$staging" -ov -format UDZO \
    "$candidate/DynamicPhotoWall-macos-arm64.dmg"
hdiutil verify "$candidate/DynamicPhotoWall-macos-arm64.dmg"
pushd "$candidate" >/dev/null
shasum -a 256 DynamicPhotoWall-macos-arm64.zip DynamicPhotoWall-macos-arm64.dmg > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
popd >/dev/null
previous=$(mktemp -d "$work/previous-release.XXXXXX")
for name in DynamicPhotoWall.app DynamicPhotoWall-macos-arm64.zip DynamicPhotoWall-macos-arm64.dmg SHA256SUMS SHA256SUMS.txt "${extras[@]}"; do
    if [[ -e "$output/$name" || -L "$output/$name" ]]; then mv "$output/$name" "$previous/$name"; fi
    if [[ -e "$candidate/$name" ]]; then mv "$candidate/$name" "$output/$name"; fi
done
echo "Local ad-hoc candidate: $output (APP/ZIP/DMG; not published; not notarized)"
echo "Previous local release: $previous"
