#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    exit 64
fi

version="$1"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dmg_path="$project_dir/dist/Codex-Bar-$version.dmg"
tag="v$version"

if [[ ! -f "$dmg_path" ]]; then
    echo "DMG not found: $dmg_path"
    echo "Run NOTARY_PROFILE=codex-bar-notary scripts/build-dmg.sh $version first."
    exit 66
fi

gh release create "$tag" "$dmg_path" \
    --title "Codex Bar $version" \
    --generate-notes \
    --verify-tag
