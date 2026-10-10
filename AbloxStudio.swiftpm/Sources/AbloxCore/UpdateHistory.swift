import Foundation

// Every version so far and what each one changed.
//
// `update.json` says only what the newest version brought. Beside it,
// `changelog.json` keeps every release's notes, newest first, so Settings →
// Updates can show the whole story. `scripts/changelog.py` adds each release
// to it from update.json, and `scripts/check-release.sh` (run by CI) fails
// when the two disagree.

public struct UpdateHistory: Codable, Equatable, Sendable {

    /// One release: the same version, build, date and notes update.json had.
    public struct Release: Codable, Equatable, Sendable, Identifiable {
        public var version: AppVersion
        public var build: Int
        /// "2026-09-26".
        public var date: String
        public var notes: [String: [String]]

        public var id: String { "\(version.description)-\(build)" }

        public init(version: AppVersion, build: Int, date: String, notes: [String: [String]]) {
            self.version = version
            self.build = build
            self.date = date
            self.notes = notes
        }

        public init(_ manifest: UpdateManifest) {
            self.init(version: manifest.version, build: manifest.build, date: manifest.date, notes: manifest.notes)
        }

        /// The notes in `language`, or English, or whatever there is.
        public func notes(for language: String) -> [String] {
            notes[language] ?? notes["en"] ?? notes.values.first ?? []
        }
    }

    /// "Ablox" or "Ablox Studio".
    public var app: String
    /// Newest first.
    public var releases: [Release]

    public init(app: String, releases: [Release]) {
        self.app = app
        self.releases = Self.ordered(releases)
    }

    public enum Limits {
        public static let maximumBytes = 512 * 1024
        public static let maximumReleases = 500
    }

    /// Reads a history from the network with the same care as update.json:
    /// small, for this app, notes cut to a sensible length, newest first.
    public static func decode(_ data: Data, forApp name: String) throws -> UpdateHistory {
        guard data.count <= Limits.maximumBytes else { throw UpdateManifest.Problem.tooLarge }
        guard let history = try? JSONDecoder().decode(UpdateHistory.self, from: data) else {
            throw UpdateManifest.Problem.unreadable
        }
        guard history.app == name else { throw UpdateManifest.Problem.otherApp(history.app) }
        let trimmed = history.releases.prefix(Limits.maximumReleases).map { release -> Release in
            var release = release
            release.notes = release.notes.mapValues { lines in
                lines.prefix(UpdateManifest.Limits.maximumNoteLines)
                    .map { String($0.prefix(UpdateManifest.Limits.maximumNoteLength)) }
            }
            return release
        }
        return UpdateHistory(app: history.app, releases: trimmed)
    }

    /// With the newest manifest in it too, in case the history has not
    /// caught up (or could not be read at all).
    public func including(_ manifest: UpdateManifest?) -> UpdateHistory {
        guard let manifest else { return self }
        return UpdateHistory(app: app, releases: releases + [Release(manifest)])
    }

    /// Newest first, one entry per version and build: a later copy of the
    /// same release is dropped.
    static func ordered(_ releases: [Release]) -> [Release] {
        var seen: Set<String> = []
        let unique = releases.filter { seen.insert($0.id).inserted }
        return unique.sorted { a, b in
            a.version == b.version ? a.build > b.build : a.version > b.version
        }
    }

    /// Where this iPad's version stands against one in the list.
    public enum Standing: Equatable, Sendable {
        case installed
        case newer
        case older
    }

    public static func standing(of release: Release, installed: AppVersion, build: Int) -> Standing {
        if release.version == installed && release.build == build { return .installed }
        let newer = release.version > installed || (release.version == installed && release.build > build)
        return newer ? .newer : .older
    }
}

extension UpdateChannel {
    /// `changelog.json` beside update.json: every version's notes.
    public var historyURL: URL? {
        manifestURL?.deletingLastPathComponent().appendingPathComponent("changelog.json")
    }
}
