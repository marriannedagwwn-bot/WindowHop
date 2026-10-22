#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${WINDOWHOP_BUILD_DIR:-$(mktemp -d -t windowhop-build)}"
app_dir="${WINDOWHOP_APP_DIR:-$project_dir/WindowHop.app}"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -swift-version 5 -target arm64-apple-macosx15.0 -O \
  "$project_dir"/Source/*.swift -o "$app_dir/Contents/MacOS/WindowHop" \
  -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit -framework Carbon
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
swift "$project_dir/Scripts/make-icon.swift" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
xattr -cr "$app_dir"
codesign --force --sign - --identifier local.windowhop.app "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
