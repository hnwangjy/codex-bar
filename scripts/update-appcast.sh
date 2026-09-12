#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <version> [build-number]"
    exit 64
fi

version="$1"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dmg_path="$project_dir/dist/Codex-Bar-$version.dmg"
appcast_path="$project_dir/appcast.xml"
sparkle_version="${SPARKLE_VERSION:-2.9.6}"
tools_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-bar-sparkle.XXXXXX")"

cleanup() { rm -rf "$tools_dir"; }
trap cleanup EXIT

if [[ ! -f "$dmg_path" ]]; then
    echo "DMG not found: $dmg_path"
    exit 66
fi

if [[ $# -eq 2 ]]; then
    build_number="$2"
else
    build_number="$(xcodebuild -project "$project_dir/codex_bar.xcodeproj" -scheme codex_bar -showBuildSettings 2>/dev/null | awk '/CURRENT_PROJECT_VERSION =/ { print $3; exit }')"
fi

if [[ -z "$build_number" ]]; then
    echo "Could not determine CURRENT_PROJECT_VERSION."
    exit 65
fi

gh release download "$sparkle_version" -R sparkle-project/Sparkle -p "Sparkle-$sparkle_version.tar.xz" -D "$tools_dir"
tar -xJf "$tools_dir/Sparkle-$sparkle_version.tar.xz" -C "$tools_dir"
signature="$($tools_dir/bin/sign_update "$dmg_path")"
ed_signature="$(printf '%s' "$signature" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
file_length="$(printf '%s' "$signature" | sed -E 's/.*length="([0-9]+)".*/\1/')"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

python3 - "$appcast_path" "$version" "$build_number" "$ed_signature" "$file_length" "$pub_date" <<'PY'
import pathlib
import sys

path, version, build, signature, length, pub_date = sys.argv[1:]
xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Codex Bar Updates</title>
    <link>https://github.com/hnwangjy/codex-bar</link>
    <description>Codex Bar stable releases</description>
    <language>en</language>
    <item>
      <title>Codex Bar {version}</title>
      <link>https://github.com/hnwangjy/codex-bar/releases/tag/v{version}</link>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <pubDate>{pub_date}</pubDate>
      <description><![CDATA[
        <p>See the GitHub release page for details about this update.</p>
      ]]></description>
      <enclosure
        url="https://github.com/hnwangjy/codex-bar/releases/download/v{version}/Codex-Bar-{version}.dmg"
        sparkle:edSignature="{signature}"
        length="{length}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
'''
pathlib.Path(path).write_text(xml, encoding="utf-8")
PY

echo "Updated $appcast_path for Codex Bar $version ($build_number)."
