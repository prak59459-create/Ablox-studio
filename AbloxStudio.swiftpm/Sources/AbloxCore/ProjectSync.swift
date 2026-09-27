import Foundation

/// Brings the Swift Playgrounds project on this iPad up to a new version by
/// writing only the files that changed.
///
/// Swift Playgrounds rebuilds only what changed since its last build. A new
/// version handed over as a new project is built from nothing, the whole app
/// every time; written into the project already there, file by file, an
/// update that touched five files costs a build of about five files.
///
/// Only the app's own files are touched: `Package.swift` and everything under
/// `Sources/`. What Swift Playgrounds keeps beside them (the icon chosen in
/// its settings, its own hidden folders) stays as it is.
public enum ProjectSync {

    public enum Problem: Error, Equatable {
        /// The folder has no `Package.swift`.
        case notAProject
        /// A project, but of another app: its bundle identifier differs.
        case otherApp(String)
    }

    /// What an update does to the project. Paths are inside the package
    /// folder, like "Sources/UI/Game/PlayScreen.swift".
    public struct Plan: Equatable, Sendable {
        public var writes: [String: [UInt8]]
        public var deletions: [String]
        public var unchanged: Int

        public var isEmpty: Bool { writes.isEmpty && deletions.isEmpty }
    }

    public static let manifest = "Package.swift"

    /// Whether a path in the package is the app's to replace.
    public static func isManaged(_ path: String) -> Bool {
        if path == manifest { return true }
        guard path.hasPrefix("Sources/") else { return false }
        // No hidden files or folders, and nothing climbing out.
        return !path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == ".." }
    }

    /// `new` is the downloaded version and `current` the project on this
    /// iPad, both as path → bytes inside the package folder.
    ///
    /// Source files the new version no longer has are deleted: a file left
    /// behind would still be compiled, and could define something twice.
    /// Anything else that is not in the new version stays.
    public static func plan(new: [String: [UInt8]], current: [String: [UInt8]]) throws -> Plan {
        guard let currentManifest = current[manifest].map({ String(decoding: $0, as: UTF8.self) }) else {
            throw Problem.notAProject
        }
        if let newManifest = new[manifest].map({ String(decoding: $0, as: UTF8.self) }),
           let expected = bundleIdentifier(inManifest: newManifest) {
            let found = bundleIdentifier(inManifest: currentManifest) ?? ""
            guard found == expected else { throw Problem.otherApp(found) }
        }

        var plan = Plan(writes: [:], deletions: [], unchanged: 0)
        for (path, bytes) in new where isManaged(path) {
            var wanted = bytes
            if path == manifest {
                wanted = Array(mergedManifest(new: String(decoding: bytes, as: UTF8.self), current: currentManifest).utf8)
            }
            if current[path] == wanted {
                plan.unchanged += 1
            } else {
                plan.writes[path] = wanted
            }
        }
        plan.deletions = current.keys
            .filter { isManaged($0) && $0.hasSuffix(".swift") && new[$0] == nil }
            .sorted()
        return plan
    }

    /// The new manifest, keeping the app icon Swift Playgrounds wrote into
    /// the old one from its settings screen. Without it the icon would go
    /// back to the placeholder on every update.
    public static func mergedManifest(new: String, current: String) -> String {
        func setting(_ name: String, in lines: [String]) -> Int? {
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") }
        }
        let currentLines = current.components(separatedBy: "\n")
        var newLines = new.components(separatedBy: "\n")
        guard setting("appIcon", in: newLines) == nil,
              let iconAt = setting("appIcon", in: currentLines),
              let anchor = setting("accentColor", in: newLines) ?? setting("supportedDeviceFamilies", in: newLines)
        else { return new }
        var icon = currentLines[iconAt]
        if !icon.trimmingCharacters(in: .whitespaces).hasSuffix(",") { icon += "," }
        newLines.insert(icon, at: anchor)
        return newLines.joined(separator: "\n")
    }

    /// The `bundleIdentifier:` a manifest gives its app, if any.
    public static func bundleIdentifier(inManifest text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("bundleIdentifier:") else { continue }
            let parts = trimmed.components(separatedBy: "\"")
            if parts.count >= 3 { return parts[1] }
        }
        return nil
    }
}
