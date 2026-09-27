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

    # Two targets: the portable core as a library, and the app on top of it.
    # Each compile job then holds one module's source rather than the whole
    # app, which is what ran an older iPad out of memory (docs/ipad-build.md).
    library_count=$(grep -cE '^\s*\.target\(' "$manifest" || true)
    app_count=$(grep -cE '^\s*\.executableTarget\(' "$manifest" || true)
    if [ "$library_count" -ne 1 ] || [ "$app_count" -ne 1 ]; then
        fail "expected one .target (AbloxCore) and one .executableTarget, found $library_count and $app_count"
    fi
    if ! grep -A1 -E '^\s*\.target\(' "$manifest" | grep -q 'name: "AbloxCore"'; then
        fail "the library target must be named AbloxCore — every file outside the core says \`import AbloxCore\`"
    fi
    product=$(grep -A1 -E '\.iOSApplication\(' "$manifest" | grep -oE 'name: "[^"]+"' | head -1 || true)
    if [ -n "$product" ] && grep -A1 -E '^\s*\.(executableTarget|target)\(' "$manifest" | grep -qF "$product"; then
        fail "a target has the app's own name ($product) — give the target a different one"
    fi

    if ! grep -q 'import AppleProductTypes' "$manifest"; then
        fail "missing \`import AppleProductTypes\` — without it .iOSApplication does not exist"
    fi
done

# ----------------------------------------------------------------- sources --

# The deployment target the manifest declares. Anything newer than this is a
# compile error on device, not a graceful degradation.
source_rules=(
    # The core is the module `AbloxCore` in both builds; EditorCore is only a
    # folder inside it.
    '\bEditorCore\.[A-Za-z_]'$'\t''EditorCore is a folder in the AbloxCore module, not a module of its own. Call it unqualified.'

    # iOS 18 API. Ablox deploys to iOS 17; see Engine/ProceduralMesh.swift.
    '\.generateCylinder\('$'\t''`MeshResource.generateCylinder(height:radius:)` is iOS 18+. Use `.abloxCylinder(height:radius:)`.'
    '\.generateCone\('$'\t''`MeshResource.generateCone(height:radius:)` is iOS 18+. Use `.abloxCone(height:radius:)`.'
    '\b(MeshGradient|onGeometryChange|sidebarAdaptable|TabSection|presentationSizing|ToolbarSpacer|glassEffect|backgroundExtensionEffect|tabBarMinimizeBehavior)\b'$'\t''this API is newer than the iOS 17 deployment target. Either provide a fallback or raise the target deliberately.'
    '@Entry\b'$'\t''`@Entry` is iOS 18+. Declare the EnvironmentKey by hand.'
    '@Previewable\b'$'\t''`@Previewable` is iOS 18+.'
)

# Only for files in the core (Sources/AbloxCore, and Studio's Sources/EditorCore).
core_rules=(
    '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+AbloxCore\b'$'\t''these files are the AbloxCore module; a module cannot import itself.'
    # Every compile job of a module loads whatever any of its files imports,
    # so one SwiftUI import here would be paid by every core job — and the
    # Linux tests could not build it at all.
    '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(SwiftUI|RealityKit|UIKit|Network|GameController|AVFoundation|AVFAudio|Combine|CoreGraphics|simd|CryptoKit|Security)\b'$'\t''the core imports Foundation alone (and Compression). Put glue to Apple frameworks in Engine/, like Engine/AppleBridging.swift.'
)

for root in "${source_roots[@]}"; do
    echo "Checking ${root#"$repo_root"/}"
    while IFS= read -r -d '' file; do
        scan "$file" "${source_rules[@]}"
        case "${file#"$root"/}" in
            AbloxCore/*|EditorCore/*)
                scan "$file" "${core_rules[@]}"
                ;;
            *)
                if ! grep -qE '^import AbloxCore$' "$file"; then
                    fail "${file#"$repo_root"/}: missing \`import AbloxCore\` — the core is its own module, so without it none of its types are in scope"
                fi
                ;;
        esac
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
