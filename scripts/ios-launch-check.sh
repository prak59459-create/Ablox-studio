#!/usr/bin/env bash
#
# Starts the app on an iPad simulator and watches it, so a crash at launch
# says where it happened. Swift Playgrounds only reports "Ablox may have
# crashed"; this prints what the app wrote (a Swift crash names its reason
# on stderr), the crash report with the crashing thread, the app's own log
# lines, and a screenshot, and fails when the app did not stay running.
#
#   scripts/ios-launch-check.sh            fresh install, watch 30 s
#   WATCH=60 scripts/ios-launch-check.sh   watch longer
#
# CI runs it on a macOS runner (.github/workflows/launch-check.yml).

set -uo pipefail
cd "$(dirname "$0")/.."

app_dir="$(ls -d *.swiftpm | head -1)"
scheme="${SCHEME:-${app_dir%.swiftpm}}"
derived="/tmp/ablox-launch-derived"
out="${OUT:-/tmp/ablox-launch}"
watch="${WATCH:-30}"
rm -rf "$derived" "$out"
mkdir -p "$out"

xcodebuild -version

# The newest iPad simulator there is.
udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
chosen = ""
for runtime in sorted(devices, key=lambda r: [int(p) for p in r.rsplit("iOS-", 1)[-1].split("-") if p.isdigit()] if "iOS" in r else [0]):
    if "iOS" not in runtime:
        continue
    for device in devices[runtime]:
        if "iPad" in device["name"]:
            chosen = device["udid"]
print(chosen)')"
if [ -z "$udid" ]; then
  echo "No iPad simulator available."
  xcrun simctl list devices available
  exit 1
fi
echo "== Simulator: $(xcrun simctl list devices | grep "$udid")"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 || true

cd "$app_dir"
schemes="$(xcodebuild -list 2>/dev/null | awk '/Schemes:/ { on = 1; next } on && NF { sub(/^[[:space:]]+/, ""); print }')"
if ! grep -qxF "$scheme" <<< "$schemes"; then
  app_target="$(grep -A1 -E '\.executableTarget\(' Package.swift | grep -oE 'name: "[^"]+"' | head -1 | cut -d'"' -f2)"
  if grep -qxF "$app_target" <<< "$schemes"; then scheme="$app_target"; else scheme="$(head -1 <<< "$schemes")"; fi
fi
echo "== Building \"$scheme\" for the simulator"
if ! xcodebuild build -scheme "$scheme" -destination "id=$udid" -derivedDataPath "$derived" \
     CODE_SIGNING_ALLOWED=NO > "$out/build.log" 2>&1; then
  echo "The build failed:"
  grep -E "error:" "$out/build.log" | head -40
  tail -30 "$out/build.log"
  exit 1
fi
cd ..

app="$(find "$derived/Build/Products" -maxdepth 2 -name "*.app" -type d | head -1)"
if [ -z "$app" ]; then
  echo "No .app was built."
  find "$derived/Build/Products" -maxdepth 3 | head -40
  exit 1
fi
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
echo "== Installing $app ($bundle)"
xcrun simctl install "$udid" "$app"

touch "$out/started"
sleep 1
echo "== Launching and watching for $watch seconds"
xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle" > "$out/console.log" 2>&1 &
launcher=$!
sleep "$watch"
xcrun simctl io "$udid" screenshot "$out/screen.png" > /dev/null 2>&1 || true

running=0
if xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -F "UIKitApplication:$bundle" | awk '{ print $1 }' | grep -qE '^[0-9]+$'; then
  running=1
fi
kill "$launcher" 2>/dev/null || true

echo
echo "== What the app wrote (stdout and stderr)"
sed -e 's/\r$//' "$out/console.log" | tail -200

echo
echo "== The app's log lines"
xcrun simctl spawn "$udid" log show --last 3m --style compact \
  --predicate "process == \"$executable\" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] \"fatal\" OR eventMessage CONTAINS[c] \"crash\")" \
  2>/dev/null | tail -120 > "$out/log.txt" || true
cat "$out/log.txt"

echo
echo "== Crash reports"
found=0
for report in $(find "$HOME/Library/Logs/DiagnosticReports" -newer "$out/started" -type f \( -name "*.ips" -o -name "*.crash" \) 2>/dev/null); do
  if grep -q "$executable" "$report"; then
    found=1
    cp "$report" "$out/"
    echo "-- $report"
    python3 - "$report" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
parts = text.split("\n", 1)
try:
    body = json.loads(parts[1])
except Exception:
    print(text[:6000])
    sys.exit()
exc = body.get("exception", {})
print("exception:", exc)
print("termination:", body.get("termination", {}))
asi = body.get("asi")
if asi:
    print("asi:", json.dumps(asi)[:3000])
images = body.get("usedImages", [])
threads = body.get("threads", [])
for t in threads:
    if not t.get("triggered"):
        continue
    print("crashed thread:", t.get("name", ""), t.get("queue", ""))
    for f in t.get("frames", [])[:60]:
        image = images[f.get("imageIndex", 0)] if f.get("imageIndex", 0) < len(images) else {}
        name = image.get("name", "?")
        symbol = f.get("symbol", "")
        loc = ""
        if "sourceFile" in f:
            loc = f" ({f['sourceFile']}:{f.get('sourceLine', '?')})"
        print(f"  {name:28} {symbol}{loc}")
PY
  fi
done
[ "$found" = 0 ] && echo "(none)"

echo
if [ "$running" = 1 ]; then
  echo "== The app is still running after $watch seconds."
else
  echo "== The app is NOT running after $watch seconds: it crashed or quit at launch."
  exit 1
fi

# Each tab opened straight away (launch argument AbloxOpenTab), so a crash
# in any tab's first screen shows here too, not only the Play tab's.
failed=""
for tab in ${TABS-Games Worlds Avatar Shop Settings}; do
  touch "$out/started-$tab"
  xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1 || true
  xcrun simctl launch --console-pty "$udid" "$bundle" -AbloxOpenTab "$tab" > "$out/console-$tab.log" 2>&1 &
  launcher=$!
  sleep "${TAB_WATCH:-12}"
  xcrun simctl io "$udid" screenshot "$out/screen-$tab.png" > /dev/null 2>&1 || true
  if xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -F "UIKitApplication:$bundle" | awk '{ print $1 }' | grep -qE '^[0-9]+$'; then
    echo "== $tab: still running"
  else
    echo "== $tab: NOT running"
    failed="$failed $tab"
    sed -e 's/\r$//' "$out/console-$tab.log" | grep -iE "fatal|error|crash|precondition" | tail -20
    for report in $(find "$HOME/Library/Logs/DiagnosticReports" -newer "$out/started-$tab" -type f -name "*.ips" 2>/dev/null); do
      grep -q "$executable" "$report" || continue
      python3 - "$report" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
body = json.loads(text.split("\n", 1)[1])
images = body.get("usedImages", [])
for t in body.get("threads", []):
    if t.get("triggered"):
        for f in t.get("frames", [])[:25]:
            i = f.get("imageIndex", 0)
            print("   ", images[i].get("name", "?") if i < len(images) else "?", f.get("symbol", ""))
PY
    done
  fi
  kill "$launcher" 2>/dev/null || true
done

if [ -n "$failed" ]; then
  echo "== Tabs that stopped the app:$failed"
  exit 1
fi
if [ -n "${TABS-x}" ]; then echo "== Every tab opened without stopping the app."; fi
