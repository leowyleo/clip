#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_bundle=${SOURCE_BUNDLE:-"$project_dir/dist/Clip.app"}
output_dir="$project_dir/dist"
staging_dir=

cleanup() {
  if [ -n "$staging_dir" ] && [ -d "$staging_dir" ]; then
    rm -rf "$staging_dir"
  fi
}
trap cleanup EXIT HUP INT TERM

if [ ! -d "$source_bundle" ]; then
  echo "Missing app bundle: $source_bundle" >&2
  echo "Build one first with UNIVERSAL=1 ./scripts/bundle.sh." >&2
  exit 2
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_bundle/Contents/Info.plist")
if [ -z "$version" ]; then
  echo "Could not read Clip version from $source_bundle/Contents/Info.plist" >&2
  exit 2
fi

mkdir -p "$output_dir"
dmg_path="$output_dir/Clip-v$version-macOS-universal.dmg"
staging_dir=$(mktemp -d "$output_dir/.clip-dmg.XXXXXX")

cp -R "$source_bundle" "$staging_dir/Clip.app"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
  -volname "Install Clip" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -ov \
  "$dmg_path" >/dev/null
hdiutil verify "$dmg_path" >/dev/null

echo "$dmg_path"
