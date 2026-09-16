#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <version> [release-notes-file]"
    exit 64
fi

version="$1"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dmg_path="$project_dir/dist/Codex-Bar-$version.dmg"
tag="v$version"
release_notes_path="${2:-$project_dir/release-notes/$version.md}"

if [[ ! -f "$dmg_path" ]]; then
    echo "DMG not found: $dmg_path"
    echo "Run NOTARY_PROFILE=codex-bar-notary scripts/build-dmg.sh $version first."
    exit 66
fi

if [[ ! -f "$release_notes_path" ]]; then
    echo "Release notes not found: $release_notes_path"
    echo "Create release-notes/$version.md before publishing."
    exit 66
fi

gh release create "$tag" "$dmg_path" \
    --title "Codex Bar $version" \
    --notes-file "$release_notes_path" \
    --verify-tag
