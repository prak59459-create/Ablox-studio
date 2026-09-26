#!/usr/bin/env bash
#
# Keeps the duplicated layers in step with the Ablox client repository.
#
# Ablox and Ablox Studio are two separate Swift Playgrounds apps, but they
# speak the same protocol, read the same world files and render with the same
# code. Those shared parts are byte-identical copies, with the Ablox
# repository as the canonical one.
#
# Why copies rather than a package dependency: Swift Playgrounds on iPad can
# only add package dependencies by git URL, which means a device needs network
# access and a resolved checkout before the project will even open. For an app
# whose whole premise is "works on an iPad with no server", making the editor
# fail to open without internet would be an odd trade. Copies keep both
# .swiftpm bundles self-contained.
#
# Every duplicated file is listed below — not just the obvious ones. A check
# that covered only AbloxCore would let DesignSystem or WorldScene drift
# silently, which is exactly the kind of divergence nobody notices until two
# iPads disagree.
#
# Usage:
#   scripts/sync-core.sh            copy from the client into this repo
#   scripts/sync-core.sh --check    exit non-zero if anything has drifted
#
# --check is what CI runs, so drift fails a build rather than being discovered
# as a protocol mismatch between two iPads in a classroom.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${ABLOX_UPSTREAM:-$(cd "$HERE/.." && pwd)/Ablox}"

UPSTREAM_APP="$UPSTREAM/Ablox.swiftpm"
LOCAL_APP="$HERE/AbloxStudio.swiftpm"

# Whole directories mirrored verbatim, relative to each app bundle.
MIRRORED_DIRS=(
  "Sources/AbloxCore"   # data model, wire format, rule engine, collision
  "Sources/Net"         # TLS, Bonjour, host, client, session coordinator
  "Sources/Engine"      # RealityKit: block entities, scene sync, avatars
)

# Individual files, "<path in client app>:<path in studio app>".
# Same path on both sides today, but spelled as a mapping so a future move on
# either side does not silently drop the file from the check.
MIRRORED_FILES=(
  "Sources/UI/Components/DesignSystem.swift:Sources/UI/Components/DesignSystem.swift"
  "Sources/UI/Components/AbloxMark.swift:Sources/UI/Components/AbloxMark.swift"
  "Sources/UI/ProjectStore.swift:Sources/UI/ProjectStore.swift"
  "Sources/UI/Components/CodePad.swift:Sources/UI/Components/CodePad.swift"
  "Sources/UI/Components/WorldHistory.swift:Sources/UI/Components/WorldHistory.swift"
)

if [[ ! -d "$UPSTREAM_APP" ]]; then
  echo "error: cannot find the Ablox client at $UPSTREAM_APP" >&2
  echo "       clone it beside this repository, or set ABLOX_UPSTREAM." >&2
  exit 2
fi

mode="sync"
if [[ "${1:-}" == "--check" ]]; then
  mode="check"
fi

drifted=0

report_drift() {
  echo "drift in $1:"
  shift
  "$@" || true
  drifted=1
}

for dir in "${MIRRORED_DIRS[@]}"; do
  src="$UPSTREAM_APP/$dir"
  dst="$LOCAL_APP/$dir"

  if [[ ! -d "$src" ]]; then
    echo "error: missing upstream directory $src" >&2
    exit 2
  fi

  if [[ "$mode" == "check" ]]; then
    if ! diff -r -q "$src" "$dst" >/dev/null 2>&1; then
      report_drift "$dir" diff -r -q "$src" "$dst"
    fi
  else
    # rm + cp rather than rsync: rsync is not installed on every CI image, and
    # this script has to work on a bare container.
    rm -rf "$dst"
    mkdir -p "$(dirname "$dst")"
    cp -R "$src" "$dst"
    echo "synced $dir"
  fi
done

for mapping in "${MIRRORED_FILES[@]}"; do
  src="$UPSTREAM_APP/${mapping%%:*}"
  dst="$LOCAL_APP/${mapping##*:}"

  if [[ ! -f "$src" ]]; then
    echo "error: missing upstream file $src" >&2
    exit 2
  fi

  if [[ "$mode" == "check" ]]; then
    if ! diff -q "$src" "$dst" >/dev/null 2>&1; then
      report_drift "${mapping##*:}" diff -q "$src" "$dst"
    fi
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "synced ${mapping##*:}"
  fi
done

# The core's tests travel with the core, so a change to either is caught here.
if [[ "$mode" == "check" ]]; then
  if ! diff -r -q "$UPSTREAM/Tests/AbloxCoreTests" "$HERE/Tests/AbloxCoreTests" >/dev/null 2>&1; then
    report_drift "Tests/AbloxCoreTests" diff -r -q "$UPSTREAM/Tests/AbloxCoreTests" "$HERE/Tests/AbloxCoreTests"
  fi

  if [[ $drifted -ne 0 ]]; then
    echo
    echo "The shared layers have drifted from the Ablox client." >&2
    echo "Run scripts/sync-core.sh to bring them back in step." >&2
    exit 1
  fi
  echo "all shared layers are in sync with $UPSTREAM"
else
  rm -rf "$HERE/Tests/AbloxCoreTests"
  cp -R "$UPSTREAM/Tests/AbloxCoreTests" "$HERE/Tests/AbloxCoreTests"
  echo "synced Tests/AbloxCoreTests"
fi
