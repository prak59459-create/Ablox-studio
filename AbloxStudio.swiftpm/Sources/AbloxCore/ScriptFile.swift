import Foundation

/// One `.absc` file: a named AbloxScript source.
///
/// A world carries any number of them. They run as one program — every file's
/// top level in order, then every file's handlers for an event — so a game can
/// keep its GUI in `ui.absc`, its weapons in `weapons.absc` and its rules in
/// `main.absc`, the way a real project is split.
public struct ScriptFile: Codable, Hashable, Identifiable, Sendable {
    public static let fileExtension = "absc"

    public var id: UUID
    public var name: String
    public var source: String
    /// Switched-off files are kept but not run — handy for trying a change.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, source: String, isEnabled: Bool = true) {
        self.id = id
        self.name = ScriptFile.cleanName(name)
        self.source = source
        self.isEnabled = isEnabled
    }

    public var isBlank: Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A safe file name ending in `.absc`: no folders, no hidden files, no
    /// characters a file system or a URL would object to.
    public static func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }
        if name.lowercased().hasSuffix(".\(fileExtension)") {
            name = String(name.dropLast(fileExtension.count + 1))
        }
        let allowed = name.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == " " }
        let trimmed = String(allowed.prefix(40)).trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? "main" : trimmed) + ".\(fileExtension)"
    }

    /// A name not already used in `existing`: `main.absc`, `main 2.absc`, …
    public static func uniqueName(_ wanted: String, among existing: [ScriptFile]) -> String {
        let clean = cleanName(wanted)
        let taken = Set(existing.map { $0.name.lowercased() })
        guard taken.contains(clean.lowercased()) else { return clean }
        let stem = String(clean.dropLast(fileExtension.count + 1))
        var number = 2
        while taken.contains("\(stem) \(number).\(fileExtension)".lowercased()) { number += 1 }
        return "\(stem) \(number).\(fileExtension)"
    }

    public enum Limits {
        /// Per world. A game split over more files than this is better as
        /// fewer, longer ones.
        public static let maximumFiles = 32
    }
}

/// A world's `.absc` files, parsed together into one program.
public struct ScriptBundle: Sendable {
    public let program: ScriptProgram
    public let fileNames: [String]

    public enum Outcome: Sendable {
        case success(ScriptBundle)
        /// Every broken file's syntax error, each naming its file.
        case failure([ScriptError])
    }

    /// Parses every enabled, non-blank file. Returns every file's syntax
    /// error at once rather than stopping at the first.
    public static func compile(_ files: [ScriptFile]) -> Outcome {
        let active = files.filter { $0.isEnabled && !$0.isBlank }
        let names = active.map(\.name)
        var programs: [ScriptProgram] = []
        var errors: [ScriptError] = []
        for (index, file) in active.enumerated() {
            do {
                programs.append(try ScriptParser.parse(file.source, file: index))
            } catch let error as ScriptError {
                errors.append(error.resolved(files: names))
            } catch {
                errors.append(ScriptError(line: 1, kind: .syntax, message: String(describing: error), file: file.name))
            }
        }
        guard errors.isEmpty else { return .failure(errors) }
        return .success(ScriptBundle(program: .combining(programs), fileNames: names))
    }
}

public extension WorldDocument {
    /// True when the world has any script worth running.
    var hasScript: Bool {
        scripts.contains { $0.isEnabled && !$0.isBlank }
    }
}
