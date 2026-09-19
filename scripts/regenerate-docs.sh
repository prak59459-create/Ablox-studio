#!/usr/bin/env bash
#
# Regenerates `docs/making-maps.md` and `docs/making-maps.ja.md` from
# `EditorCore/MapGuide.swift`.
#
# The map-making guide has two audiences — the sheet inside Studio and this
# repository — and one source. Editing the Markdown by hand would make the app
# and the docs disagree, so `MapGuideTests.testTheMarkdownFileMatchesTheGuide`
# fails when they do. Change MapGuide.swift, run this, commit both.
#
# There is no SwiftPM executable target for this on purpose: adding one to the
# root manifest would be another thing that has to stay in step with the app
# manifest, for a script that runs by hand a few times a year. Instead the
# portable sources are compiled directly — the same set the test package
# compiles, which is everything except the layers that need an Apple SDK.
#
# Usage: scripts/regenerate-docs.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo_root/AbloxStudio.swiftpm"
output="$repo_root/docs/making-maps.md"
output_ja="$repo_root/docs/making-maps.ja.md"

if ! command -v swiftc > /dev/null; then
    echo "error: swiftc not found. Install a Swift toolchain, or let CI catch the drift." >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# `main.swift` so top-level code is allowed. No `import AbloxCore`: on device
# and here alike these files are one module, which is the whole reason the app
# can stay a single target.
cat > "$work/main.swift" <<'SWIFT'
import Foundation

// One pass per language. `MapGuide.markdown` reads whatever `Localization`
// is set to, which is the same mechanism the app uses — so if the Japanese
// document is wrong, the Japanese guide in Studio is wrong the same way.
for (language, path) in [(Language.english, CommandLine.arguments[1]),
                         (Language.japanese, CommandLine.arguments[2])] {
    Localization.language = language
    try! MapGuide.markdown.write(toFile: path, atomically: true, encoding: .utf8)
}
SWIFT

# The same exclusions as the root Package.swift: everything that needs SwiftUI,
# RealityKit or Network is left out, and what remains builds anywhere.
mapfile -t sources < <(
    find "$app/Sources" -name '*.swift' \
        -not -path '*/Net/*' \
        -not -path '*/Engine/*' \
        -not -path '*/Editor/*' \
        -not -path '*/UI/*' \
        -not -name 'StudioApp.swift'
)

swiftc "${sources[@]}" "$work/main.swift" -o "$work/emit"
"$work/emit" "$output" "$output_ja"

echo "wrote ${output#"$repo_root"/} and ${output_ja#"$repo_root"/}"
