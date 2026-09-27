#!/usr/bin/env bash
#
# Builds the app with the real iOS SDK (for the simulator, so nothing needs
# signing) and lists where the compiler spends its time: the slowest
# function bodies and expressions, and the build's own timing summary.
#
# Swift Playgrounds on an older iPad takes minutes over what a Mac does in
# seconds, and it runs out of memory on the same few functions. This is how
# those functions are found without an iPad. CI runs it on a macOS runner.
#
#   scripts/ios-build-times.sh            full build, report
#   KEEP_LOG=/path scripts/ios-build-times.sh   also keep the raw log

set -uo pipefail
cd "$(dirname "$0")/.."

app_dir="$(ls -d *.swiftpm | head -1)"
scheme="${SCHEME:-${app_dir%.swiftpm}}"
log="${KEEP_LOG:-/tmp/ios-build.log}"
derived="/tmp/ablox-derived"
rm -rf "$derived"

xcodebuild -version
cd "$app_dir"

stats="/tmp/ablox-stats"
rm -rf "$stats"; mkdir -p "$stats"
flags="-Xfrontend -debug-time-function-bodies -Xfrontend -warn-long-expression-type-checking=150 -Xfrontend -stats-output-dir -Xfrontend $stats"
start=$(date +%s)
xcodebuild build \
  -scheme "$scheme" \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived" \
  -showBuildTimingSummary \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS="$flags" > "$log" 2>&1
status=$?
end=$(date +%s)

echo
echo "== Build finished with status $status in $((end - start)) s"

echo
echo "== Slowest function bodies (ms, where, what)"
grep -E '^[0-9]+(\.[0-9]+)?ms[[:space:]]' "$log" \
  | sed "s|$PWD/||" \
  | sort -rn | awk -F'\t' '!seen[$2]++' | head -40 || true

echo
echo "== Time per file (sum of its function bodies, ms)"
grep -E '^[0-9]+(\.[0-9]+)?ms[[:space:]]' "$log" \
  | sed "s|$PWD/||" \
  | awk -F'\t' '!seen[$2]++ { split($2, where, ":"); ms = $1; sub(/ms$/, "", ms); total[where[1]] += ms }
                END { for (f in total) printf "%10.1f  %s\n", total[f], f }' \
  | sort -rn | head -30 || true

echo
echo "== Slow expressions"
grep -E "warning: expression took|warning: .* took [0-9]+ms to type-check" "$log" | sed "s|$PWD/||" | sort -u | head -60

echo
echo "== Compiler phases, summed over every compile job (seconds)"
python3 - "$stats" <<'PY'
import glob, json, sys, collections
total = collections.Counter()
jobs = 0
for path in glob.glob(sys.argv[1] + "/*.json"):
    try:
        data = json.load(open(path))
    except Exception:
        continue
    jobs += 1
    for key, value in data.items():
        if key.startswith("time.swift.") and key.endswith(".wall"):
            total[key[len("time.swift."):-len(".wall")]] += value
        if key.startswith("time.swift-frontend.") and key.endswith(".wall"):
            total["frontend " + key[len("time.swift-frontend."):-len(".wall")]] += value
print(f"{jobs} jobs")
for name, seconds in total.most_common(30):
    print(f"{seconds:9.2f}  {name}")
PY

echo
echo "== Build timing summary"
sed -n '/Build Timing Summary/,/^\*\* BUILD/p' "$log" | head -60

echo
echo "== Errors"
grep -E "error:" "$log" | sed "s|$PWD/||" | sort -u | head -400

exit $status
