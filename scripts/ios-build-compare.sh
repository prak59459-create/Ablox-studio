#!/usr/bin/env bash
#
# What one build setting is worth: builds the app several times in one go,
# alternating with and without the setting, over the same warm module cache
# (as on an iPad that has built before). Runner speed varies a lot from job
# to job, so only builds in the same job are compared.
#
#   COMPARE="GCC_GENERATE_DEBUGGING_SYMBOLS=NO" scripts/ios-build-compare.sh
#
# CI runs it from Actions with the "compare" input filled in.

set -uo pipefail
cd "$(dirname "$0")/.."

app_dir="$(ls -d *.swiftpm | head -1)"
scheme="${SCHEME:-${app_dir%.swiftpm}}"
derived="/tmp/ablox-compare"
read -r -a changed <<< "${COMPARE:?set COMPARE to the build settings to try}"
rm -rf "$derived"

xcodebuild -version
cd "$app_dir"

schemes="$(xcodebuild -list 2>/dev/null | awk '/Schemes:/ { on = 1; next } on && NF { sub(/^[[:space:]]+/, ""); print }')"
if ! grep -qxF "$scheme" <<< "$schemes"; then
  app_target="$(grep -A1 -E '\.executableTarget\(' Package.swift | grep -oE 'name: "[^"]+"' | head -1 | cut -d'"' -f2)"
  if grep -qxF "$app_target" <<< "$schemes"; then scheme="$app_target"; else scheme="$(head -1 <<< "$schemes")"; fi
fi

build() {
  local label="$1"; shift
  local log="/tmp/compare-$label.log"
  xcodebuild clean -scheme "$scheme" -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" > /dev/null 2>&1
  local start end status
  start=$(date +%s)
  xcodebuild build \
    -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" \
    -showBuildTimingSummary \
    ARCHS=arm64 \
    CODE_SIGNING_ALLOWED=NO \
    "$@" > "$log" 2>&1
  status=$?
  end=$(date +%s)
  local swift emit
  swift="$(grep -E '^SwiftCompile \([0-9]+ tasks?\) \|' "$log" | sed 's/.*| //')"
  emit="$(grep -E '^SwiftEmitModule \([0-9]+ tasks?\) \|' "$log" | sed 's/.*| //')"
  printf "%-14s status %s  %4d s   Swift compiling %s   interfaces %s\n" \
    "$label" "$status" $((end - start)) "${swift:-?}" "${emit:-?}"
  [ "$status" -eq 0 ] || grep -E "error:" "$log" | sort -u | head -20
}

echo
echo "== Comparing: ${changed[*]}"
build warm-up
build plain
build changed "${changed[@]}"
build plain-again
build changed-again "${changed[@]}"
