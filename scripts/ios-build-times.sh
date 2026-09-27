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
#   PER_FILE=1 scripts/ios-build-times.sh       one file per compile job, so
#                                               each file's own cost is listed

set -uo pipefail
cd "$(dirname "$0")/.."

app_dir="$(ls -d *.swiftpm | head -1)"
scheme="${SCHEME:-${app_dir%.swiftpm}}"
log="${KEEP_LOG:-/tmp/ios-build.log}"
derived="/tmp/ablox-derived"
rm -rf "$derived"

xcodebuild -version
cd "$app_dir"

# Xcode names the schemes after the package's products and targets, and the
# set changes with the targets. When the expected one is missing, build the
# app's own target instead, and say which schemes there were.
schemes="$(xcodebuild -list 2>/dev/null | awk '/Schemes:/ { on = 1; next } on && NF { sub(/^[[:space:]]+/, ""); print }')"
if ! grep -qxF "$scheme" <<< "$schemes"; then
  echo "No scheme named \"$scheme\". The package has:"
  sed 's/^/  /' <<< "$schemes"
  app_target="$(grep -A1 -E '\.executableTarget\(' Package.swift | grep -oE 'name: "[^"]+"' | head -1 | cut -d'"' -f2)"
  if grep -qxF "$app_target" <<< "$schemes"; then scheme="$app_target"; else scheme="$(head -1 <<< "$schemes")"; fi
  echo "Building \"$scheme\"."
fi

stats="/tmp/ablox-stats"
rm -rf "$stats"; mkdir -p "$stats"
flags="-Xfrontend -debug-time-function-bodies -Xfrontend -warn-long-expression-type-checking=150 -Xfrontend -stats-output-dir -Xfrontend $stats"
# Slower overall (every job reads every file), but the statistics then belong
# to one file each, code generation included.
batch="YES"
if [ -n "${PER_FILE:-}" ]; then batch="NO"; fi
start=$(date +%s)
xcodebuild build \
  -scheme "$scheme" \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived" \
  -showBuildTimingSummary \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_ENABLE_BATCH_MODE="$batch" \
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

if [ -n "${PER_FILE:-}" ]; then
echo
echo "== Cost per file, one compile job each (seconds: total = imports + checking + SILGen + IRGen + the rest, mostly LLVM)"
python3 - "$stats" <<'PY'
import glob, json, sys, collections
rows = []
modules = collections.Counter()
for path in glob.glob(sys.argv[1] + "/*.json"):
    try:
        data = json.load(open(path))
    except Exception:
        continue
    name = next((k[len("time.swift-frontend."):-len(".wall")] for k in data
                 if k.startswith("time.swift-frontend.") and k.endswith(".wall")), None)
    if not name:
        continue
    total = data["time.swift-frontend." + name + ".wall"]
    module, _, rest = name.partition("-")
    label = rest.split(".swift")[0] if ".swift" in rest else "(interface)"
    part = lambda key: data.get("time.swift." + key + ".wall", 0.0)
    imports, sema, silgen, irgen = part("parse-and-resolve-imports"), part("perform-sema"), part("SILGen"), part("IRGen")
    other = max(0.0, total - imports - sema - silgen - irgen)
    rows.append((total, module, label, imports, sema, silgen, irgen, other))
    modules[module] += total
print(f"{len(rows)} jobs; per module: " + ", ".join(f"{m} {t:.1f}" for m, t in modules.most_common()))
print(f"{'total':>7} {'import':>7} {'check':>7} {'SILGen':>7} {'IRGen':>7} {'rest':>7}  file")
for total, module, label, imports, sema, silgen, irgen, other in sorted(rows, reverse=True)[:60]:
    print(f"{total:7.2f} {imports:7.2f} {sema:7.2f} {silgen:7.2f} {irgen:7.2f} {other:7.2f}  {module}/{label}")
PY
fi

echo
echo "== Largest object files (KB, lines): the code each file turned into"
find "$derived" -name '*.o' -path '*arm64*' -print0 2>/dev/null \
  | xargs -0 stat -f '%z %N' 2>/dev/null | sort -rn | head -40 \
  | while read -r size path; do
      name="$(basename "$path" .o)"
      source="$(find . -name "$name.swift" | head -1)"
      lines="$( [ -n "$source" ] && wc -l < "$source" | tr -d ' ' || echo "?")"
      printf "%8d %6s  %s\n" $((size / 1024)) "$lines" "${source:-$name}"
    done

echo
echo "== Build timing summary"
sed -n '/Build Timing Summary/,/^\*\* BUILD/p' "$log" | head -60

echo
echo "== Errors"
grep -E "error:" "$log" | sed "s|$PWD/||" | sort -u | head -400

exit $status
