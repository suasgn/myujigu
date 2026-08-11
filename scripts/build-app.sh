#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
bundle_dir="$project_dir/.build/$configuration/Myujigu.app"
contents_dir="$bundle_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$project_dir"
swift build --disable-sandbox -c "$configuration" --product Myujigu
binary_dir="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"

if [[ -d "$bundle_dir" ]]; then
  rm -rf "$bundle_dir"
fi
mkdir -p "$macos_dir" "$resources_dir"
cp "$binary_dir/Myujigu" "$macos_dir/Myujigu"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"
chmod +x "$macos_dir/Myujigu"

codesign --force --deep --sign - "$bundle_dir"
print "Built $bundle_dir"
