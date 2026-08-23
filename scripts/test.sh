#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}

cd "$project_dir"

case "$developer_dir" in
  */CommandLineTools)
    framework_dir="$developer_dir/Library/Developer/Frameworks"
    swift_runtime_dir="$developer_dir/Library/Developer/usr/lib"
    DEVELOPER_DIR="$developer_dir" xcrun swift test \
      -Xswiftc -F -Xswiftc "$framework_dir" \
      -Xlinker -F -Xlinker "$framework_dir" \
      -Xlinker -rpath -Xlinker "$framework_dir" \
      -Xlinker -rpath -Xlinker "$swift_runtime_dir"
    ;;
  *)
    DEVELOPER_DIR="$developer_dir" xcrun swift test
    ;;
esac
