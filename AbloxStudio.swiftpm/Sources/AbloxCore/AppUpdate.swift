import Foundation

// Keeping the app itself up to date.
//
// Ablox is a Swift Playgrounds project, not an App Store app: nothing on the
// iPad replaces it by itself. What the app can do — and does, without being
// asked — is notice that a newer version is out, download it, unpack the
// project, back up everything first, and hand the new project to Swift
// Playgrounds in one tap. What is left for a person is tapping it.
//
// The decisions live here, in the portable core, where they are tested: what
// counts as newer, what a published manifest may say, where to download
// from, and which files in the download are the project. `AppUpdater` does
// the networking and the files.

// MARK: - Version

/// "1.2.3": a version people read, compared number by number.
public struct AppVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy(\.isASCII), let n = Int(piece), n >= 0 else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// 1.2 and 1.2.0 are the same version.
    private var padded: [Int] { parts + Array(repeating: 0, count: 4 - parts.count) }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.padded.lexicographicallyPrecedes(rhs.padded)
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.padded == rhs.padded }
    public func hash(into hasher: inout Hasher) { hasher.combine(padded) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = AppVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Manifest

/// `update.json` at the top of the app's repository: what the newest version
/// is and what changed. Written by `scripts/release.sh`, checked by CI to
/// agree with the project's own version, read by every iPad.
public struct UpdateManifest: Codable, Equatable, Sendable {
    /// Which app this is for — "Ablox" or "Ablox Studio" — so pointing one at
    /// the other's repository cannot offer the wrong project.
    public var app: String
    public var version: AppVersion
    /// Counts up with every release, even one that keeps the version.
    public var build: Int
    /// `AbloxProtocol.version` in that release. A different one means the
    /// new version and this one cannot play together.
    public var protocolVersion: Int
    /// "2026-09-26".
    public var date: String
    /// The project folder inside the repository: "Ablox.swiftpm".
    public var package: String
    /// What changed, a few lines per language ("en", "ja").
    public var notes: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case app, version, build, date, package, notes
        case protocolVersion = "protocol"
    }

    public init(app: String, version: AppVersion, build: Int, protocolVersion: Int, date: String, package: String,
                notes: [String: [String]]) {
        self.app = app
        self.version = version
        self.build = build
        self.protocolVersion = protocolVersion
        self.date = date
        self.package = package
        self.notes = notes
    }

    public enum Limits {
        public static let maximumBytes = 32 * 1024
        public static let maximumNoteLines = 20
        public static let maximumNoteLength = 300
    }

    public enum Problem: Error, Equatable {
        case unreadable
        case tooLarge
        case otherApp(String)
        case badPackage
    }

    /// Reads a manifest, holding it to the same care as anything else from
    /// the network: small, for this app, naming a project folder that is
    /// only a folder name, with notes cut to a sensible length.
    public static func decode(_ data: Data, forApp name: String) throws -> UpdateManifest {
        guard data.count <= Limits.maximumBytes else { throw Problem.tooLarge }
        guard var manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else { throw Problem.unreadable }
        guard manifest.app == name else { throw Problem.otherApp(manifest.app) }
        guard manifest.package.hasSuffix(".swiftpm"), ZipArchive.safePath(manifest.package) == manifest.package,
              !manifest.package.contains("/") else { throw Problem.badPackage }
        manifest.notes = manifest.notes.mapValues { lines in
            lines.prefix(Limits.maximumNoteLines).map { String($0.prefix(Limits.maximumNoteLength)) }
        }
        return manifest
    }

    /// The notes in `language`, or English, or whatever there is.
    public func notes(for language: String) -> [String] {
        notes[language] ?? notes["en"] ?? notes.values.first ?? []
    }
}

// MARK: - This app

/// Which app is running, which version it is, and where new ones come from.
public struct InstalledApp: Sendable {
    public let app: String
    public let version: AppVersion
    public let build: Int
    /// The project folder: "Ablox.swiftpm".
    public let package: String
    public let channel: UpdateChannel

    public init(app: String, version: String, build: Int, package: String, channel: UpdateChannel) {
        self.app = app
        self.version = AppVersion(version) ?? AppVersion("0")!
        self.build = build
        self.package = package
        self.channel = channel
    }
}

// MARK: - What to do

public enum UpdateAvailability: Equatable, Sendable {
    /// Nothing newer.
    case current
    /// A newer version. `required` when it speaks a different network
    /// protocol: friends who have it cannot play with this iPad until it
    /// updates too.
    case newer(required: Bool)
}

public enum UpdatePolicy {
    /// How often to look without being asked.
    public static let checkInterval: TimeInterval = 6 * 60 * 60

    public static func availability(installed: AppVersion, build: Int, manifest: UpdateManifest) -> UpdateAvailability {
        let newer = manifest.version > installed || (manifest.version == installed && manifest.build > build)
        guard newer else { return .current }
        return .newer(required: manifest.protocolVersion != AbloxProtocol.version)
    }

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        // A clock set backwards should not stop checks for good.
        return now.timeIntervalSince(lastCheck) >= checkInterval || now < lastCheck
    }

    /// A version the player chose to skip is not offered again — unless it
    /// is required, or something newer comes out.
    public static func shouldOffer(_ manifest: UpdateManifest, availability: UpdateAvailability, skipped: AppVersion?) -> Bool {
        guard case let .newer(required) = availability else { return false }
        if required { return true }
        guard let skipped else { return true }
        return manifest.version > skipped
    }
}

// MARK: - Where from

/// A public GitHub repository an app updates from.
public struct UpdateChannel: Equatable, Sendable {
    public let owner: String
    public let repository: String
    /// "HEAD" follows whatever the repository's default branch is.
    public let branch: String

    public init(owner: String, repository: String, branch: String = "HEAD") {
        self.owner = owner
        self.repository = repository
        self.branch = branch
    }

    private var isValid: Bool {
        func plain(_ s: String) -> Bool {
            !s.isEmpty && s.count <= 100 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } && !s.hasPrefix(".")
        }
        let branchOK = !branch.isEmpty && branch.count <= 100 && !branch.contains("..") && !branch.hasPrefix("/")
            && branch.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0)) }
        return plain(owner) && plain(repository) && branchOK
    }

    /// `update.json` on the raw file server, which has no rate limit to
    /// speak of — a classroom of iPads checking at once is fine.
    public var manifestURL: URL? {
        guard isValid else { return nil }
        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(branch)/update.json")
    }

    /// The whole repository as a zip. GitHub redirects this to its archive
    /// server, and URLSession follows.
    public var archiveURL: URL? {
        guard isValid else { return nil }
        let ref = branch == "HEAD" ? "HEAD" : "refs/heads/\(branch)"
        return URL(string: "https://github.com/\(owner)/\(repository)/archive/\(ref).zip")
    }

    /// Where a person can read about it.
    public var pageURL: URL? {
        guard isValid else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repository)")
    }
}

// MARK: - The downloaded project

/// The app's project folder, found in a repository zip and checked.
public struct UpdatePackage {

    public enum Limits {
        public static let maximumFiles = 4_000
        public static let maximumBytes = 150 * 1024 * 1024
    }

    public enum Problem: Error, Equatable {
        case notFound(String)
        case noManifest
        case tooLarge
        case unsafePath(String)
        case archive(ZipArchive.Failure)
    }

    /// Relative paths, starting with the package folder
    /// ("Ablox.swiftpm/Package.swift"), and each file's bytes.
    public let files: [(path: String, bytes: [UInt8])]
    public let folders: [String]

    /// GitHub's zips put everything in one top folder named after the
    /// repository and commit ("Ablox-3f2a…/"). The package is the folder
    /// called `package` directly inside it.
    public init(archive: ZipArchive, package: String) throws {
        var files: [(String, [UInt8])] = []
        var folders: Set<String> = []
        var total = 0
        var sawManifest = false
        for entry in archive.entries {
            let parts = entry.name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let inside = String(parts[1])
            guard inside == package + "/" || inside.hasPrefix(package + "/") else { continue }
            guard let path = ZipArchive.safePath(inside) else { throw Problem.unsafePath(entry.name) }
            if entry.isDirectory {
                folders.insert(path)
                continue
            }
            // Finder's leftovers are not part of anyone's project.
            if path.split(separator: "/").contains(where: { $0 == "__MACOSX" || $0 == ".DS_Store" }) { continue }
            guard files.count < Limits.maximumFiles else { throw Problem.tooLarge }
            total += entry.size
            guard total <= Limits.maximumBytes else { throw Problem.tooLarge }
            do {
                files.append((path, try archive.contents(of: entry)))
            } catch let failure as ZipArchive.Failure {
                throw Problem.archive(failure)
            }
            if path == package + "/Package.swift" { sawManifest = true }
            // Every folder a file sits in, so an archive without folder
            // entries still unpacks.
            var folder = (path as NSString).deletingLastPathComponent
            while !folder.isEmpty, folder != "." {
                folders.insert(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        guard !files.isEmpty || !folders.isEmpty else { throw Problem.notFound(package) }
        guard sawManifest else { throw Problem.noManifest }
        self.files = files
        self.folders = folders.sorted()
    }

    /// Writes the project into `directory`, replacing an older copy there.
    public func write(into directory: URL) throws {
        let manager = FileManager.default
        if let top = files.first?.path.split(separator: "/").first {
            try? manager.removeItem(at: directory.appendingPathComponent(String(top)))
        }
        for folder in folders {
            try manager.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in files {
            let url = directory.appendingPathComponent(file.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.bytes).write(to: url, options: [.atomic])
        }
    }
}
