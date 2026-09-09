#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: NOTARY_PROFILE=codex-bar-notary $0 <version>"
    exit 64
fi

version="$1"
team_id="${DEVELOPMENT_TEAM:-64XC9BXK5K}"
identity="${CODE_SIGN_IDENTITY:-Developer ID Application}"
notary_profile="${NOTARY_PROFILE:-}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$project_dir/dist"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-bar-release.XXXXXX")"
archive_path="$work_dir/CodexBar.xcarchive"
staging_dir="$work_dir/dmg"
app_path="$archive_path/Products/Applications/codex_bar.app"
staged_app="$staging_dir/Codex Bar.app"
app_zip="$work_dir/Codex-Bar.app.zip"
dmg_path="$output_dir/Codex-Bar-$version.dmg"

cleanup() {
    exit_code=$?
    trap - EXIT
    rm -rf "$work_dir"
    exit "$exit_code"
}
trap cleanup EXIT

if [[ -z "$notary_profile" ]]; then
    echo "NOTARY_PROFILE is required for a notarized public release."
    echo "Create one with: xcrun notarytool store-credentials codex-bar-notary"
    exit 64
fi

if ! security find-identity -v -p codesigning | grep -Fq 'Developer ID Application'; then
    echo "No valid Developer ID Application certificate was found in the login keychain."
    echo "Create one in Xcode > Settings > Accounts > Manage Certificates."
    exit 65
fi

mkdir -p "$output_dir" "$staging_dir"

echo "Archiving Codex Bar ${version}…"
xcodebuild archive \
    -project "$project_dir/codex_bar.xcodeproj" \
    -scheme codex_bar \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity" \
    MARKETING_VERSION="$version" \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

if [[ ! -d "$app_path" ]]; then
    echo "Archived app was not found at $app_path"
    exit 66
fi

codesign --verify --deep --strict --verbose=2 "$app_path"

echo "Notarizing the application…"
ditto -c -k --keepParent "$app_path" "$app_zip"
xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app_path"

ditto "$app_path" "$staged_app"
ln -s /Applications "$staging_dir/Applications"

echo "Creating ${dmg_path}…"
hdiutil create \
    -volname "Codex Bar" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

codesign --force --timestamp --sign "$identity" "$dmg_path"

echo "Notarizing the disk image…"
xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg_path"

spctl --assess --type execute --verbose=2 "$app_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

echo "Release DMG created: $dmg_path"
