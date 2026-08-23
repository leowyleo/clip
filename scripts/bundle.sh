#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-release}
local_signing_identity="Clip Local Development"
signing_identity=${SIGNING_IDENTITY:-}
bundle_dir="$project_dir/dist/Clip.app"
staging_dir=
universal_executable=

cleanup() {
  if [ -n "$staging_dir" ] && [ -d "$staging_dir" ]; then
    rm -rf "$staging_dir"
  fi
  if [ -n "$universal_executable" ] && [ -f "$universal_executable" ]; then
    rm -f "$universal_executable"
  fi
}
trap cleanup EXIT HUP INT TERM

if [ -z "$signing_identity" ]; then
  login_keychain=$(security default-keychain -d user \
    | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
  if security find-identity -v -p codesigning "$login_keychain" \
      | grep -Fq "\"$local_signing_identity\""; then
    signing_identity=$local_signing_identity
  else
    echo "Missing local signing identity: $local_signing_identity" >&2
    echo "Run scripts/create-local-signing-identity.sh once, or explicitly set SIGNING_IDENTITY." >&2
    exit 2
  fi
fi

cd "$project_dir"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c "$configuration" --product Clip --arch arm64
  swift build -c "$configuration" --product Clip --arch x86_64
  arm_executable="$project_dir/.build/arm64-apple-macosx/$configuration/Clip"
  intel_executable="$project_dir/.build/x86_64-apple-macosx/$configuration/Clip"
  universal_executable=$(mktemp "$project_dir/.build/Clip.universal.XXXXXX")
  lipo -create \
    "$arm_executable" \
    "$intel_executable" \
    -output "$universal_executable"
  executable_path="$universal_executable"
else
  swift build -c "$configuration" --product Clip
  executable_path="$project_dir/.build/$configuration/Clip"
fi

mkdir -p "$project_dir/dist"
staging_dir=$(mktemp -d "$project_dir/dist/.clip-bundle.XXXXXX")
staged_bundle="$staging_dir/Clip.app"
contents_dir="$staged_bundle/Contents"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$executable_path" "$contents_dir/MacOS/Clip"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"

if [ "$signing_identity" = "-" ]; then
  codesign --force --deep --sign - "$staged_bundle"
elif [ "$signing_identity" = "$local_signing_identity" ]; then
  codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$signing_identity" \
    "$staged_bundle"
else
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$staged_bundle"
fi

codesign --verify --deep --strict --verbose=2 "$staged_bundle"

previous_bundle="$project_dir/dist/.Clip.previous.$$"
if [ -e "$previous_bundle" ]; then
  echo "Refusing to replace existing temporary bundle: $previous_bundle" >&2
  exit 2
fi
if [ -e "$bundle_dir" ]; then
  mv "$bundle_dir" "$previous_bundle"
fi
if ! mv "$staged_bundle" "$bundle_dir"; then
  if [ -e "$previous_bundle" ]; then
    mv "$previous_bundle" "$bundle_dir"
  fi
  exit 1
fi
if [ -e "$previous_bundle" ]; then
  rm -rf "$previous_bundle"
fi

echo "$bundle_dir"
