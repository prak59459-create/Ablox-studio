#!/usr/bin/env bash
#
# Decides whether this push gets a new .ipa, so that every .ipa on the "ipa"
# release carries a version higher than the one before it:
#
#   scripts/ipa-version-check.sh        prints build=true or build=false
#
# - A higher version (or build) than the published .ipa: build it.
# - The same version, and the app is unchanged since the published one
#   (only docs or scripts changed): nothing new, so no new .ipa.
# - The same version but the app changed: fail. Raise the version first
#   with scripts/release.sh <next version>.
# - A lower version (an older branch): keep the newer .ipa that is there.
#
# Run by .github/workflows/ipa.yml before the build. PUBLISHED may point at
# a local altstore-source.json instead of the release (for trying it out).

set -euo pipefail
cd "$(dirname "$0")/.."

app_dir="$(ls -d *.swiftpm | head -1)"
version="$(sed -nE 's/.*displayVersion: "([^"]*)".*/\1/p' "$app_dir/Package.swift" | head -1)"
build="$(sed -nE 's/.*bundleVersion: "([^"]*)".*/\1/p' "$app_dir/Package.swift" | head -1)"
origin_repo="$(git config --get remote.origin.url 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?/?$#\1#p')"
repo="${GITHUB_REPOSITORY:-${origin_repo:-prak59459-create/Ablox}}"
published="${PUBLISHED:-https://github.com/$repo/releases/download/ipa/altstore-source.json}"

say() { echo "build=$1"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "build=$1" >> "$GITHUB_OUTPUT"; return 0; }

if [ -f "$published" ]; then source_json="$(cat "$published")"; else source_json="$(curl -fsSL "$published" 2>/dev/null || true)"; fi
if [ -z "$source_json" ]; then
  echo "No .ipa published yet: building $version ($build)."
  say true; exit 0
fi
read -r old_version old_build < <(python3 -c '
import json, sys
app = json.loads(sys.argv[1])["apps"][0]
print(app["version"], app["versions"][0].get("buildVersion", "0"))' "$source_json")

# Compared as numbers, version then build: 6.10 is newer than 6.9.
order="$(python3 -c '
import sys
key = lambda v, b: [int(x) for x in v.split(".")] + [int(b)]
new, old = key(sys.argv[1], sys.argv[2]), key(sys.argv[3], sys.argv[4])
print("same" if new == old else "newer" if new > old else "older")' "$version" "$build" "$old_version" "$old_build")"
if [ "$order" != same ]; then
  if [ "$order" = newer ]; then
    echo "New version: $old_version ($old_build) → $version ($build)."
    say true
  else
    echo "::notice::$version ($build) is older than the published $old_version ($old_build); keeping that one."
    say false
  fi
  exit 0
fi

# The same version as the published .ipa: fine only if the app is the same.
git fetch -q --tags --force origin 2>/dev/null || true
if published_sha="$(git rev-parse -q --verify 'refs/tags/ipa^{commit}')" \
   && git cat-file -e "$published_sha" 2>/dev/null \
   && git diff --quiet "$published_sha" HEAD -- "$app_dir"; then
  echo "The app is unchanged since the published $version ($build): no new .ipa."
  say false; exit 0
fi
echo "::error::The app changed but its version is still $version ($build), the same as the published .ipa. Raise it first: scripts/release.sh <next version>"
exit 1
