#!/usr/bin/env bash
#
# Keeps the shared layers in step with the Ablox client repository.
#
# Ablox and Ablox Studio are two separate Swift Playgrounds apps, but they
# speak the same protocol and read the same world files. `AbloxCore` and `Net`
# are therefore identical in both, with the Ablox repository as the canonical
# copy.
#
# Why a mirror rather than a package dependency: Swift Playgrounds on iPad can
# only add package dependencies by git URL, which means a device needs network
# access and a resolved checkout before the project will even open. For an app
# whose whole premise is "works on an iPad with no server", making the editor
# fail to open without internet would be an odd trade. Mirrored files keep both
# .swiftpm bundles self-contained.
#
# Usage:
#   scripts/sync-core.sh            copy from ../Ablox into this repo
#   scripts/sync-core.sh --check    exit non-zero if anything has drifted
#
# --check is what CI runs, so drift fails a build rather than being discovered
# as a protocol mismatch between two iPads.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${ABLOX_UPSTREAM:-$(cd "$HERE/.." && pwd)/Ablox}"

MIRRORED_DIRS=(
  "Sources/AbloxCore"
  "Sources/Net"
)

UPSTREAM_APP="$UPSTREAM/Ablox.swiftpm"
LOCAL_APP="$HERE/AbloxStudio.swiftpm"

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

for dir in "${MIRRORED_DIRS[@]}"; do
  src="$UPSTREAM_APP/$dir"
  dst="$LOCAL_APP/$dir"

  if [[ ! -d "$src" ]]; then
    echo "error: missing upstream directory $src" >&2
    exit 2
  fi

  if [[ "$mode" == "check" ]]; then
    if ! diff -r -q "$src" "$dst" >/dev/null 2>&1; then
      echo "drift in $dir:"
      diff -r -q "$src" "$dst" || true
      drifted=1
    fi
  else
    mkdir -p "$dst"
    rsync -a --delete "$src/" "$dst/"
    echo "synced $dir"
  fi
done

# The core tests travel with the core, so a change to either is caught here.
if [[ "$mode" == "check" ]]; then
  if ! diff -r -q "$UPSTREAM/Tests/AbloxCoreTests" "$HERE/Tests/AbloxCoreTests" >/dev/null 2>&1; then
    echo "drift in Tests/AbloxCoreTests:"
    diff -r -q "$UPSTREAM/Tests/AbloxCoreTests" "$HERE/Tests/AbloxCoreTests" || true
    drifted=1
  fi

  if [[ $drifted -ne 0 ]]; then
    echo
    echo "The shared layers have drifted from the Ablox client." >&2
    echo "Run scripts/sync-core.sh to bring them back in step." >&2
    exit 1
  fi
  echo "shared layers are in sync with $UPSTREAM"
else
  rsync -a --delete "$UPSTREAM/Tests/AbloxCoreTests/" "$HERE/Tests/AbloxCoreTests/"
  echo "synced Tests/AbloxCoreTests"
fi
