#!/usr/bin/env bash
#
# Guards the Swift Playgrounds app manifest against patterns that a real iPad
# has already rejected.
#
# `AppleProductTypes` ships only inside Swift Playgrounds and Xcode, so the app
# manifest cannot be compiled on Linux and CI cannot type-check it. Every error
# in it has had to be found by the person holding the iPad, one round-trip at a
# time. This script cannot validate the API — it can only make sure a spelling
# that was already proven wrong does not come back.
#
# See docs/swift-playgrounds-manifest.md for what the device has confirmed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

fail() {
    printf '  \033[31m✗\033[0m %s\n' "$1"
    status=1
}

# Each rule is "regex<TAB>explanation". The regex is matched against the
# manifest with `grep -E`; a match is a failure.
rules=(
    'appIcon:[[:space:]]*\.placeholder'$'\t''PlaceholderIcon member names are unverifiable here; two guesses (.hammer, .cube) were rejected on device, and a wrong one stops the project opening. Omit appIcon: and set the icon from the app-settings screen.'
    '\.portrait\('$'\t''InterfaceOrientation exposes static properties, not functions. Use `.portrait`; leave upside-down out of the list instead of passing `upsideDown:`.'
    '\.landscapeRight\('$'\t''InterfaceOrientation exposes static properties, not functions. Use `.landscapeRight`.'
    '\.landscapeLeft\('$'\t''InterfaceOrientation exposes static properties, not functions. Use `.landscapeLeft`.'
    'bonjourServices:'$'\t''The argument label is `bonjourServiceTypes:`.'
)

shopt -s nullglob
manifests=("$repo_root"/*.swiftpm/Package.swift)
shopt -u nullglob

if [ ${#manifests[@]} -eq 0 ]; then
    echo "No .swiftpm/Package.swift found under $repo_root" >&2
    exit 1
fi

for manifest in "${manifests[@]}"; do
    echo "Checking ${manifest#"$repo_root"/}"

    for rule in "${rules[@]}"; do
        pattern="${rule%%$'\t'*}"
        message="${rule#*$'\t'}"
        # Comment lines are skipped: these notes explain the rejected spellings
        # and would otherwise trip the rule that documents them.
        hits=$(grep -nE "$pattern" "$manifest" | grep -vE '^[0-9]+:[[:space:]]*//' || true)
        if [ -n "$hits" ]; then
            fail "$message"
            printf '%s\n' "$hits" | sed 's/^/      /'
        fi
    done

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

if [ "$status" -eq 0 ]; then
    printf '  \033[32m✓\033[0m no known-bad manifest patterns\n'
fi

exit "$status"
