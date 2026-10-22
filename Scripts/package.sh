#!/bin/bash
# Build reusable installation files without changing the installed application.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${WINDOWHOP_APP_DIR:-$project_dir/WindowHop.app}"
release_dir="${WINDOWHOP_RELEASE_DIR:-$project_dir/dist}"
if [[ ! -d "$app_dir" ]]; then
  WINDOWHOP_APP_DIR="$app_dir" "$project_dir/Scripts/build.sh"
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
expected_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")
if [[ "$version" != "$expected_version" ]]; then
  printf 'Version mismatch: app %s, source %s. Rebuild before packaging.\n' "$version" "$expected_version" >&2
  exit 1
fi
codesign --verify --strict "$app_dir"
if [[ "$(lipo -archs "$app_dir/Contents/MacOS/WindowHop")" != "arm64" ]]; then
  printf 'This packaging script expects an arm64 build.\n' >&2
  exit 1
fi
mkdir -p "$release_dir"
release_dir="$(cd "$release_dir" && pwd)"
stage_dir=$(mktemp -d -t windowhop-package)
trap 'rm -rf "$stage_dir"' EXIT
payload_dir="$stage_dir/WindowHop"
mkdir -p "$payload_dir"
ditto --norsrc --noextattr "$app_dir" "$payload_dir/WindowHop.app"
cp "$project_dir/LICENSE" "$payload_dir/LICENSE"
cat > "$payload_dir/安装说明.txt" <<'TXT'
跃窗 WindowHop

系统要求：Apple Silicon（M 系列芯片），macOS 15 或更新系统。

1. 将 WindowHop.app 拖入“应用程序”。
2. 从“应用程序”打开 WindowHop，在设置中允许“辅助功能”。
3. 如需窗口缩略图，再允许“屏幕录制”，按系统提示退出并重新打开应用。
4. 默认按 Control + Option + Tab 打开列表，继续按 Tab 选择，松开修饰键切换。
   也可点击设置中的“打开窗口列表”。

当前安装包使用 ad-hoc 签名，尚未通过 Apple 公证。
如系统拦截打开，请在尝试启动后进入“系统设置 → 隐私与安全性”，
检查被拦截的应用并按系统提供的“仍要打开”流程处理。

源码、更新与反馈：https://github.com/marriannedagwwn-bot/WindowHop
协议：MIT，见同目录 LICENSE。
TXT
zip_path="$release_dir/WindowHop-$version-arm64.zip"
dmg_path="$release_dir/WindowHop-$version-arm64.dmg"
if [[ -e "$zip_path" || -e "$dmg_path" ]]; then
  printf 'Release files already exist in %s. Choose a new output directory.\n' "$release_dir" >&2
  exit 1
fi
ditto -c -k --keepParent --norsrc --noextattr "$payload_dir" "$zip_path"
ln -s /Applications "$payload_dir/Applications"
hdiutil create -volname WindowHop -srcfolder "$payload_dir" -format UDZO -ov "$dmg_path"
hdiutil verify "$dmg_path"
(cd "$release_dir" && shasum -a 256 "WindowHop-$version-arm64.dmg" "WindowHop-$version-arm64.zip" > SHA256SUMS.txt)
printf 'Packaged:\n%s\n%s\n' "$dmg_path" "$zip_path"
