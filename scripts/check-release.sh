#!/usr/bin/env bash
#
# Fails if the app's version is not the same in Package.swift, AppRelease.swift
# and update.json, or if update.json names a different network protocol than
# the code speaks. See scripts/release.sh.

set -euo pipefail
cd "$(dirname "$0")/.."

app_dir="$(ls -d *.swiftpm | head -1)"
python3 - "$app_dir" <<'PY'
import json, re, sys
app_dir = sys.argv[1]
def grab(path, pattern):
    m = re.search(pattern, open(path).read())
    if not m:
        sys.exit(f"✗ could not find {pattern} in {path}")
    return m.group(1)

def norm(v):
    parts = [int(p) for p in v.split(".")]
    return parts + [0] * (4 - len(parts))

package_version = grab(f"{app_dir}/Package.swift", r'displayVersion: "([^"]*)"')
package_build = grab(f"{app_dir}/Package.swift", r'bundleVersion: "([^"]*)"')
release_version = grab(f"{app_dir}/Sources/AppRelease.swift", r'static let version = "([^"]*)"')
release_build = grab(f"{app_dir}/Sources/AppRelease.swift", r'static let build = (\d+)')
protocol = grab(f"{app_dir}/Sources/AbloxCore/Packets.swift", r'public static let version = (\d+)')
update = json.load(open("update.json"))

problems = []
if norm(package_version) != norm(release_version) or norm(release_version) != norm(update["version"]):
    problems.append(f"version: Package.swift {package_version}, AppRelease.swift {release_version}, update.json {update['version']}")
if not (package_build == release_build == str(update["build"])):
    problems.append(f"build: Package.swift {package_build}, AppRelease.swift {release_build}, update.json {update['build']}")
if str(update["protocol"]) != protocol:
    problems.append(f"update.json says protocol {update['protocol']}, the code speaks {protocol}")
if update.get("package") != app_dir:
    problems.append(f"update.json package is {update.get('package')}, the project is {app_dir}")
for language in ("en", "ja"):
    if not update.get("notes", {}).get(language):
        problems.append(f"update.json has no {language} notes")
if problems:
    print("✗ release details disagree — run scripts/release.sh:")
    for p in problems:
        print("   ", p)
    sys.exit(1)
print(f"✓ {app_dir} {release_version} ({release_build}), protocol {protocol}: Package.swift, AppRelease.swift and update.json agree")
PY
