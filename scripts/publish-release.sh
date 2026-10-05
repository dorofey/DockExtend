#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

version="${1:-}"
if [[ -z "$version" ]]; then
  echo "Usage: scripts/publish-release.sh <version>" >&2
  exit 2
fi
if [[ ! "$version" =~ '^[0-9]+(\.[0-9]+){2}$' ]]; then
  echo "Version must use MAJOR.MINOR.PATCH (for example 0.1.0)." >&2
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash work before publishing a release." >&2
  exit 1
fi
if ! command -v gh >/dev/null || ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "Authenticate gh to the dorofey account before publishing." >&2
  exit 1
fi

sparkle_tools="${SPARKLE_TOOLS:-}"
if [[ -z "$sparkle_tools" ]]; then
  sparkle_tools="$project_dir/.release-tools/bin"
  if [[ ! -x "$sparkle_tools/generate_appcast" ]]; then
    mkdir -p "$project_dir/.release-tools"
    curl -L --fail \
      https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
      -o "$project_dir/.release-tools/Sparkle-2.10.0.tar.xz"
    tar -xf "$project_dir/.release-tools/Sparkle-2.10.0.tar.xz" -C "$project_dir/.release-tools"
  fi
fi
if [[ ! -x "$sparkle_tools/generate_appcast" ]]; then
  echo "Could not find generate_appcast in $sparkle_tools" >&2
  exit 1
fi

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' AppBundle/Contents/Info.plist)"
if [[ "$bundle_version" != "$version" ]]; then
  echo "Set CFBundleShortVersionString to $version before publishing (currently $bundle_version)." >&2
  exit 1
fi
gh_user="$(gh api user --jq .login)"
if [[ "$gh_user" != "dorofey" ]]; then
  echo "The active GitHub account is $gh_user; authenticate gh to dorofey before publishing." >&2
  exit 1
fi

updates_dir="$project_dir/.release/$version"
rm -rf "$updates_dir"
mkdir -p "$updates_dir"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" \
APP_VERSION="$version" \
APP_BUILD_NUMBER="$version" \
  ./scripts/build-app.sh

ditto -c -k --sequesterRsrc --keepParent DockExtend.app "$updates_dir/DockExtend-macos.zip"
awk -v version="$version" '
  $0 == "## " version { found = 1; next }
  found && /^## / { exit }
  found { print }
' CHANGELOG.md > "$updates_dir/DockExtend-macos.md"
if [[ ! -s "$updates_dir/DockExtend-macos.md" ]]; then
  echo "Add a ## $version entry to CHANGELOG.md before publishing." >&2
  exit 1
fi

"$sparkle_tools/generate_appcast" \
  --download-url-prefix "https://github.com/dorofey/DockExtend/releases/latest/download/" \
  --release-notes-url-prefix "https://github.com/dorofey/DockExtend/releases/latest/download/" \
  --link "https://github.com/dorofey/DockExtend" \
  "$updates_dir"

cp "$updates_dir/appcast.xml" appcast.xml
git add appcast.xml
git commit -m "Publish DockExtend $version appcast"
git push origin main
gh release create "v$version" \
  "$updates_dir/DockExtend-macos.zip" \
  "$updates_dir/DockExtend-macos.md" \
  --title "DockExtend $version" \
  --notes-file "$updates_dir/DockExtend-macos.md"
