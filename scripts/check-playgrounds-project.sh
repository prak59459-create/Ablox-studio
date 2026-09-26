#!/usr/bin/env bash
#
# Guards the Swift Playgrounds app against mistakes a real iPad has already
# rejected.
#
# Two parts of this project cannot be compiled anywhere but on device:
#
#   * the app manifest, which imports `AppleProductTypes` — a module that
#     ships only inside Swift Playgrounds and Xcode; and
#   * everything under Sources/ that touches SwiftUI, RealityKit or Network,
#     which needs the iOS SDK.
#
# CI can build and test AbloxCore on Linux, and it can parse every file for
# syntax, but neither of those sees an argument label that does not exist or an
# API that arrived in a later iOS. Every one of those has had to be found by
# the person holding the iPad, one round-trip at a time.
#
# This script cannot type-check any of it. All it does is refuse a spelling
# that has already cost a round-trip, so the same one cannot come back. See
# docs/ipad-build.md for what the device has actually said.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

fail() {
    printf '  \033[31m✗\033[0m %s\n' "$1"
    status=1
}

# Each rule is "regex<TAB>explanation". A match is a failure. Comment lines are
# skipped, so the notes explaining a rejected spelling do not trip the rule
# that documents it.
scan() {
    local file="$1"
    shift
    local rule pattern message hits
    for rule in "$@"; do
        pattern="${rule%%$'\t'*}"
        message="${rule#*$'\t'}"
        hits=$(grep -nE "$pattern" "$file" | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
        if [ -n "$hits" ]; then
            fail "${file#"$repo_root"/}: $message"
            printf '%s\n' "$hits" | sed 's/^/      /'
        fi
    done
}

# ---------------------------------------------------------------- manifest --

manifest_rules=(
    'appIcon:[[:space:]]*\.placeholder'$'\t''PlaceholderIcon member names are unverifiable here; two guesses (.hammer, .cube) were rejected on device, and a wrong one stops the project opening. Omit appIcon: and set the icon from the app-settings screen.'
    '\.portrait\('$'\t''InterfaceOrientation exposes static properties, not functions. Use `.portrait`; leave upside-down out of the list instead of passing `upsideDown:`.'
    '\.landscape(Right|Left)\('$'\t''InterfaceOrientation exposes static properties, not functions. Drop the parentheses.'
    'bonjourServices:'$'\t''The argument label is `bonjourServiceTypes:`.'
)

shopt -s nullglob
manifests=("$repo_root"/*.swiftpm/Package.swift)
source_roots=("$repo_root"/*.swiftpm/Sources)
shopt -u nullglob

if [ ${#manifests[@]} -eq 0 ]; then
    echo "No .swiftpm/Package.swift found under $repo_root" >&2
    exit 1
fi

for manifest in "${manifests[@]}"; do
    echo "Checking ${manifest#"$repo_root"/}"
    scan "$manifest" "${manifest_rules[@]}"

    # The app must stay a single executable target: Swift Playgrounds builds an
    # App project as one module, and splitting it has broken loading before.
    target_count=$(grep -cE '^\s*\.(executableTarget|target)\(' "$manifest" || true)
    if [ "$target_count" -ne 1 ]; then
        fail "expected exactly one target, found $target_count — Swift Playgrounds App projects are built as a single module"
    fi

    if ! grep -q 'import AppleProductTypes' "$manifest"; then
        fail "missing \`import AppleProductTypes\` — without it .iOSApplication does not exist"
    fi
done

# ----------------------------------------------------------------- sources --

# The deployment target the manifest declares. Anything newer than this is a
# compile error on device, not a graceful degradation.
source_rules=(
    # The app is one module named after its target (`AbloxApp` /
    # `AbloxStudioApp`); the off-device test package compiles the same files as
    # `AbloxCore`. Naming either one only works in one of the two builds.
    '\b(AbloxCore|EditorCore)\.[A-Za-z_]'$'\t''module-qualified reference: on device these sources are one module with a different name, so this cannot resolve. Call the function unqualified, or write the expression out.'
    '^[[:space:]]*import[[:space:]]+(AbloxCore|EditorCore)[[:space:]]*$'$'\t''there is no such module on device — the app is a single target. Delete the import.'

    # iOS 18 API. Ablox deploys to iOS 17; see Engine/ProceduralMesh.swift.
    '\.generateCylinder\('$'\t''`MeshResource.generateCylinder(height:radius:)` is iOS 18+. Use `.abloxCylinder(height:radius:)`.'
    '\.generateCone\('$'\t''`MeshResource.generateCone(height:radius:)` is iOS 18+. Use `.abloxCone(height:radius:)`.'
    '\b(MeshGradient|onGeometryChange|sidebarAdaptable|TabSection|presentationSizing|ToolbarSpacer|glassEffect|backgroundExtensionEffect|tabBarMinimizeBehavior)\b'$'\t''this API is newer than the iOS 17 deployment target. Either provide a fallback or raise the target deliberately.'
    '@Entry\b'$'\t''`@Entry` is iOS 18+. Declare the EnvironmentKey by hand.'
    '@Previewable\b'$'\t''`@Previewable` is iOS 18+.'
)

for root in "${source_roots[@]}"; do
    echo "Checking ${root#"$repo_root"/}"
    while IFS= read -r -d '' file; do
        scan "$file" "${source_rules[@]}"
    done < <(find "$root" -name '*.swift' -print0)
done

# ------------------------------------------------------------ translation --
#
# Both apps must be showable in English and Japanese. Delegated to a Python
# script because the checks need to understand Swift string literals —
# escaped quotes, and `\(interpolations)` that are not words to translate.

if command -v python3 > /dev/null; then
    "$repo_root/scripts/check-translations.py" "$repo_root" || status=1
else
    echo "  ! python3 not found; skipping the translation check"
fi

# ---------------------------------------------------------------- release --
#
# The version in Package.swift, AppRelease.swift and update.json must agree,
# or iPads are offered an update that never arrives. See scripts/release.sh.

if command -v python3 > /dev/null && [ -f "$repo_root/update.json" ]; then
    "$repo_root/scripts/check-release.sh" || status=1
fi

if [ "$status" -eq 0 ]; then
    printf '  \033[32m✓\033[0m no known-bad patterns\n'
fi

exit "$status"
