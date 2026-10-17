#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="artifacts/macos/verification"
mkdir -p "$output"
if [[ "${1:-}" == "--unit-only" ]]; then
    set -- -only-testing:DynamicPhotoWallTests
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--unit-only]" >&2
    exit 2
else
    set --
fi
xcodebuild test -project macos/DynamicPhotoWall.xcodeproj -scheme DynamicPhotoWall \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$output/DerivedData" \
    APP_BUNDLE_IDENTIFIER=asia.dix.mhanayama.DynamicPhotoWall.Regression \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES \
    "$@" 2>&1 | tee "$output/tests.log"
dotnet run --project tests/ParityVerifier -- macos/DynamicPhotoWallTests/Fixtures/WindowsParity.json \
    2>&1 | tee "$output/windows-core-fixtures.log"
xcodebuild build -project macos/DynamicPhotoWall.xcodeproj -scheme DynamicPhotoWall \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$output/ReleaseDerivedData" CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$output/release-build.log"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$output/ReleaseDerivedData/Build/Products/Release/DynamicPhotoWall.app/Contents/Info.plist")" == "true" ]]
echo "Tests, shared Windows fixtures, and arm64 Release compilation passed. OS acceptance is a separate release gate."
