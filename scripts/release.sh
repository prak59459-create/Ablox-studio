#!/usr/bin/env bash
#
# Starts a new release: one command changes the version everywhere it lives.
#
#   scripts/release.sh 1.2          next build number, today's date
#   scripts/release.sh 1.2 7        a given build number
#
# The version is in three places, and they must agree or iPads are told
# about an update that never arrives (or told forever about one they have):
#
#   <App>.swiftpm/Package.swift          displayVersion / bundleVersion
#   <App>.swiftpm/Sources/AppRelease.swift   version / build
#   update.json                          what every iPad reads to find out
#
# update.json also gets today's date and the current network protocol. Its
# "notes" are the one thing written by hand: a few lines, in English and
# Japanese, on what changed. Push to the default branch and every iPad with
# automatic updates on finds it within a few hours.
#
# scripts/check-release.sh (run by CI) checks the three agree.

set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
  echo "usage: scripts/release.sh <version like 1.2> [build]" >&2
  exit 2
fi

app_dir="$(ls -d *.swiftpm | head -1)"
manifest="$app_dir/Package.swift"
release="$app_dir/Sources/AppRelease.swift"
current_build="$(sed -nE 's/.*static let build = ([0-9]+).*/\1/p' "$release")"
build="${2:-$((current_build + 1))}"
protocol="$(sed -nE 's/.*public static let version = ([0-9]+).*/\1/p' "$app_dir/Sources/AbloxCore/Packets.swift")"
today="$(date -u +%Y-%m-%d)"

sed -i.bak -E "s/displayVersion: \"[^\"]*\"/displayVersion: \"$version\"/; s/bundleVersion: \"[^\"]*\"/bundleVersion: \"$build\"/" "$manifest"
sed -i.bak -E "s/static let version = \"[^\"]*\"/static let version = \"$version\"/; s/static let build = [0-9]+/static let build = $build/" "$release"
rm -f "$manifest.bak" "$release.bak"

python3 - "$version" "$build" "$protocol" "$today" <<'PY'
import json, sys
version, build, protocol, today = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
with open("update.json") as f:
    data = json.load(f)
data.update(version=version, build=build, protocol=protocol, date=today)
with open("update.json", "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "✓ $app_dir is now $version ($build), protocol $protocol, dated $today"
echo "  Now write what changed in update.json \"notes\" (en and ja), then commit and push."
