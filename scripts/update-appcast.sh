#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "Usage: $0 <version> [build-number] [release-notes-file]"
    exit 64
fi

version="$1"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dmg_path="$project_dir/dist/Codex-Bar-$version.dmg"
appcast_path="$project_dir/appcast.xml"
release_notes_path="${3:-$project_dir/release-notes/$version.md}"
sparkle_version="${SPARKLE_VERSION:-2.9.6}"
tools_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-bar-sparkle.XXXXXX")"

cleanup() { rm -rf "$tools_dir"; }
trap cleanup EXIT

if [[ ! -f "$dmg_path" ]]; then
    echo "DMG not found: $dmg_path"
    exit 66
fi

if [[ ! -f "$release_notes_path" ]]; then
    echo "Release notes not found: $release_notes_path"
    echo "Create release-notes/$version.md before publishing."
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

python3 - "$appcast_path" "$release_notes_path" "$version" "$build_number" "$ed_signature" "$file_length" "$pub_date" <<'PY'
import html
import pathlib
import re
import sys

path, notes_path, version, build, signature, length, pub_date = sys.argv[1:]

def inline_markup(value):
    escaped = html.escape(value)
    return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)

def markdown_to_html(markdown):
    output = []
    in_list = False
    for raw_line in markdown.splitlines():
        line = raw_line.strip()
        if line.startswith("# "):
            continue
        if line.startswith("## "):
            if in_list:
                output.append("</ul>")
                in_list = False
            output.append(f"<h3>{inline_markup(line[3:])}</h3>")
        elif line.startswith("- "):
            if not in_list:
                output.append("<ul>")
                in_list = True
            output.append(f"<li>{inline_markup(line[2:])}</li>")
        elif line:
            if in_list:
                output.append("</ul>")
                in_list = False
            output.append(f"<p>{inline_markup(line)}</p>")
    if in_list:
        output.append("</ul>")
    return "\n        ".join(output).replace("]]>", "]]&gt;")

release_notes_html = markdown_to_html(pathlib.Path(notes_path).read_text(encoding="utf-8"))
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
        {release_notes_html}
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
