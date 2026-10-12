#!/usr/bin/env bash
#
# Builds the app for a real iPad and packs it as an unsigned .ipa:
#
#   scripts/build-ipa.sh            -> $OUT/<App>-<version>.ipa
#
# Unsigned because signing needs an Apple account; a sideloading app
# (AltStore, Sideloadly, …) signs it with yours when it installs it.
# CI runs it on every push and attaches the file to the "ipa" release
# (.github/workflows/ipa.yml).

set -euo pipefail
cd "$(dirname "$0")/.."

app_dir="$(ls -d *.swiftpm | head -1)"
scheme="${SCHEME:-${app_dir%.swiftpm}}"
derived="/tmp/ipa-derived"
out="${OUT:-/tmp/ipa}"
rm -rf "$derived" "$out"
mkdir -p "$out"
version="$(sed -nE 's/.*displayVersion: "([^"]*)".*/\1/p' "$app_dir/Package.swift" | head -1)"

cd "$app_dir"
schemes="$(xcodebuild -list 2>/dev/null | awk '/Schemes:/ { on = 1; next } on && NF { sub(/^[[:space:]]+/, ""); print }')"
if ! grep -qxF "$scheme" <<< "$schemes"; then
  app_target="$(grep -A1 -E '\.executableTarget\(' Package.swift | grep -oE 'name: "[^"]+"' | head -1 | cut -d'"' -f2)"
  if grep -qxF "$app_target" <<< "$schemes"; then scheme="$app_target"; else scheme="$(head -1 <<< "$schemes")"; fi
fi
echo "== Building \"$scheme\" $version for iPad"
if ! xcodebuild build -scheme "$scheme" -configuration Release -destination 'generic/platform=iOS' \
     -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
     > "$out/build.log" 2>&1; then
  grep -E "error:" "$out/build.log" | head -40
  tail -30 "$out/build.log"
  exit 1
fi
cd ..

app="$(find "$derived/Build/Products" -maxdepth 2 -path '*iphoneos*' -name "*.app" -type d | head -1)"
[ -n "$app" ] || { echo "No .app was built."; find "$derived/Build/Products" -maxdepth 3; exit 1; }
name="$(basename "$app" .app)"
mkdir -p "$out/pack/Payload"
cp -R "$app" "$out/pack/Payload/"
ipa="$out/${name// /}-$version.ipa"
(cd "$out/pack" && zip -qry "$ipa" Payload)
rm -rf "$out/pack"
echo "== $ipa ($(du -h "$ipa" | cut -f1))"

# An AltStore source beside it: add its address in AltStore once
# (Browse → Sources → +), and every new build shows up there as an update.
repo="${GITHUB_REPOSITORY:-prak59459-create/Ablox}"
base="https://github.com/$repo/releases/download/ipa"
plist="$app/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || echo 1)"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist" 2>/dev/null || echo 17.0)"
icon="$(find "$app" -maxdepth 1 -name 'AppIcon*.png' -print0 | xargs -0 ls -S 2>/dev/null | head -1 || true)"
stable="$out/${name// /}.ipa"
cp "$ipa" "$stable"
[ -n "$icon" ] && cp "$icon" "$out/icon.png"
NAME="$name" BUNDLE="$bundle" VERSION="$version" BUILD="$build" MINIMUM="$minimum" BASE="$base" REPO="$repo" \
SIZE="$(stat -f %z "$stable")" FILE="$(basename "$stable")" ICON="$([ -n "$icon" ] && echo yes)" python3 - "$out/altstore-source.json" <<'PY'
import json, os, sys, datetime
e = os.environ
today = datetime.date.today().isoformat()
app = {
    "name": e["NAME"], "bundleIdentifier": e["BUNDLE"], "developerName": "Ablox",
    "subtitle": "Build and play 3D games with friends" if "Studio" not in e["NAME"] else "Make Ablox games",
    "localizedDescription": "Built from github.com/" + e["REPO"] + " on every push.",
    "iconURL": e["BASE"] + "/icon.png" if e.get("ICON") else "",
    "tintColor": "#22D3EE",
    "version": e["VERSION"], "versionDate": today, "downloadURL": e["BASE"] + "/" + e["FILE"], "size": int(e["SIZE"]),
    "versions": [{"version": e["VERSION"], "buildVersion": e["BUILD"], "date": today, "size": int(e["SIZE"]),
                  "downloadURL": e["BASE"] + "/" + e["FILE"], "minOSVersion": e["MINIMUM"]}],
    "appPermissions": {"entitlements": [], "privacy": {}},
}
source = {"name": e["NAME"], "identifier": e["BUNDLE"] + ".source", "subtitle": "Ablox builds",
          "website": "https://github.com/" + e["REPO"], "apps": [app], "news": []}
json.dump(source, open(sys.argv[1], "w"), indent=2)
PY
echo "== AltStore source: $base/altstore-source.json"
