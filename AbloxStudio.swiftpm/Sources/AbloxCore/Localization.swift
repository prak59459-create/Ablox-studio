import Foundation

/// English and Japanese, without a resource bundle.
///
/// ## Why not `.lproj` and `NSLocalizedString`
///
/// The usual way needs the target to declare resources, which means editing
/// the Swift Playgrounds app manifest — the one file in this project that
/// cannot be compiled anywhere but on an iPad, and that has already cost four
/// round-trips (see `docs/ipad-build.md`). It would also put the translations
/// somewhere `swift test` on Linux cannot read them.
///
/// A plain Swift dictionary has neither problem. It compiles in the portable
/// core, so the tests can assert that every English string has a Japanese one,
/// that their placeholders agree, and that no key is defined twice — none of
/// which a `.strings` file gives you until someone notices a screen in the
/// wrong language.
///
/// ## The English string is the key
///
/// `L("Play")` rather than `L(.playButton)`. There is no key vocabulary to
/// invent or keep in step, a missing translation degrades to readable English
/// instead of a raw identifier, and the untranslated call sites are findable
/// by eye. `scripts/check-playgrounds-project.sh` fails on a user-facing
/// literal that is not wrapped.
public enum Language: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case english = "en"
    case japanese = "ja"

    public var id: String { rawValue }

    /// Written in its own language on purpose: someone looking at a UI they
    /// cannot read still needs to recognise the entry for theirs.
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }
}

/// What the player chose, which is not the same as what they get.
public enum LanguagePreference: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    /// Follow the iPad's own language.
    case system
    case english
    case japanese

    public var id: String { rawValue }

    /// Resolves to a language, given the device's preferred list.
    ///
    /// Anything that is not Japanese resolves to English rather than to
    /// nothing: a Korean iPad gets a UI it can at least navigate.
    public func language(preferredCodes: [String]) -> Language {
        switch self {
        case .english: return .english
        case .japanese: return .japanese
        case .system:
            for code in preferredCodes {
                // Matches "ja", "ja-JP" and "ja_JP" without matching "java".
                let normalised = code.replacingOccurrences(of: "_", with: "-").lowercased()
                if normalised == "ja" || normalised.hasPrefix("ja-") {
                    return .japanese
                }
            }
            return .english
        }
    }

    /// The label for this option, in the language it selects — so the Japanese
    /// row reads as Japanese even while the app is in English.
    public var displayName: String {
        switch self {
        case .system: return L("Match the iPad")
        case .english: return Language.english.displayName
        case .japanese: return Language.japanese.displayName
        }
    }
}

/// The language the app is currently drawing in.
///
/// A global rather than an environment value, because otherwise every one of
/// the ~250 call sites would need to reach an `@Environment`, including the
/// ones in the portable core that have no SwiftUI at all. SwiftUI does not
/// observe it, so the apps hang `.id(preference)` on the view below their
/// state objects: changing the language rebuilds the tree once, which is both
/// correct and rare enough not to matter.
public enum Localization {

    // Plain `static var` plus a lock, matching `BlockEntityFactory`'s cache.
    // Deliberately not `nonisolated(unsafe)`: that spelling needs Swift 5.10,
    // and the compiler inside Swift Playgrounds is not something this project
    // can check before shipping.
    private static let lock = NSLock()
    private static var _language: Language = .english

    public static var language: Language {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _language
        }
        set {
            lock.lock()
            _language = newValue
            lock.unlock()
        }
    }

    /// Looks `english` up in the current language.
    ///
    /// An unknown string returns itself. That is the deliberate failure mode:
    /// a screen half-translated is confusing, but a screen with one English
    /// line is merely unpolished, and the app never shows a key.
    public static func text(_ english: String) -> String {
        guard language == .japanese else { return english }
        return Strings.japanese[english] ?? english
    }

    /// As `text(_:)`, with `{}` replaced left to right by the arguments.
    ///
    /// `{}` rather than `%@`: `String(format:)` handles `%@` differently on
    /// Linux than on Apple platforms, and this has to behave identically in
    /// the tests and on the iPad. It also lets a test check that a translation
    /// kept the same number of holes as its original.
    public static func text(_ english: String, _ arguments: [CustomStringConvertible]) -> String {
        fill(text(english), with: arguments)
    }

    /// Substitutes `{}` placeholders. Extra arguments are ignored and extra
    /// placeholders are left as they are — neither should happen, and
    /// `LocalizationTests` proves neither does, but a formatting slip must not
    /// be a crash in someone's hands.
    public static func fill(_ template: String, with arguments: [CustomStringConvertible]) -> String {
        guard !arguments.isEmpty else { return template }

        var result = ""
        var remaining = arguments[...]
        var rest = Substring(template)

        while let hole = rest.range(of: "{}") {
            result += rest[rest.startIndex..<hole.lowerBound]
            if let next = remaining.first {
                result += next.description
                remaining = remaining.dropFirst()
            } else {
                result += "{}"
            }
            rest = rest[hole.upperBound...]
        }

        return result + rest
    }

    /// The number of `{}` holes in a string.
    public static func placeholderCount(in template: String) -> Int {
        var count = 0
        var rest = Substring(template)
        while let hole = rest.range(of: "{}") {
            count += 1
            rest = rest[hole.upperBound...]
        }
        return count
    }
}

/// Translates a user-facing string. See `Localization`.
public func L(_ english: String) -> String {
    Localization.text(english)
}

/// Translates a user-facing string and fills its `{}` placeholders.
public func L(_ english: String, _ arguments: CustomStringConvertible...) -> String {
    Localization.text(english, arguments)
}
