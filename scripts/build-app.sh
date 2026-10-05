#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
DEVELOPER_DIR="$developer_dir" swift build -c release

app_bundle="$project_dir/DockExtend.app"
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Frameworks"
binary_path="$project_dir/.build/out/Products/Release/DockExtend"
if [[ ! -x "$binary_path" ]]; then
  binary_path="$project_dir/.build/arm64-apple-macosx/release/DockExtend"
fi
cp "$binary_path" "$app_bundle/Contents/MacOS/DockExtend"
cp "$project_dir/AppBundle/Contents/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$project_dir/AppBundle/Resources/DockExtend.icns" "$app_bundle/Contents/Resources/DockExtend.icns"
app_version="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")}"
build_number="${APP_BUILD_NUMBER:-$app_version}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
cp "$project_dir/Sources/DockExtend/Resources/HerdrLogo.svg" "$app_bundle/Contents/Resources/HerdrLogo.svg"
cp "$project_dir/Sources/DockExtend/Resources/OpenAILogo.svg" "$app_bundle/Contents/Resources/OpenAILogo.svg"
cp "$project_dir/Sources/DockExtend/Resources/ClaudeLogo.svg" "$app_bundle/Contents/Resources/ClaudeLogo.svg"
sparkle_framework="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
  echo "Sparkle.framework was not found at $sparkle_framework" >&2
  exit 1
fi
ditto "$sparkle_framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_bundle/Contents/MacOS/DockExtend"
chmod +x "$app_bundle/Contents/MacOS/DockExtend"

echo "Built $app_bundle"
