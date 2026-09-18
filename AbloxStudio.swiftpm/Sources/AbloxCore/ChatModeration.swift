import Foundation

/// Chat safety: a word filter and a per-device mute list.
///
/// ## What this is, and what it is not
///
/// This is a **speed bump, not a safety system**. A substring filter is
/// trivially defeated by anyone who wants to — spacing, substitution,
/// misspelling — and no word list is complete or culturally neutral. It exists
/// because the alternative, a totally unfiltered channel between children, is
/// worse, and because seeing `***` is a clear signal that someone is being
/// watched.
///
/// The real protections in Ablox are structural, and they matter more than the
/// list: sessions are local-only and never touch a server, joining needs a
/// room code shared in person, and everyone in a session is in the same room.
/// Muting is the control that always works, so it is one tap from any message.
///
/// The list below is deliberately short and mild. A long list of slurs shipped
/// inside a children's Playground would be its own problem, and a filter that
/// mangles ordinary words ("classic", "assignment") teaches children the
/// filter is broken. Hosts should be able to extend it — see `additionalTerms`.
public struct ChatModerator: Sendable {

    // MARK: Filtering

    /// The built-in list: mild profanity and the common insults that start
    /// playground arguments. Lowercase, matched case-insensitively.
    public static let defaultBlockedTerms: [String] = [
        "damn", "crap", "stupid", "idiot", "dumb", "loser",
        "shutup", "shut up", "hate you", "kill you", "ugly"
    ]

    /// Extra terms a host adds for their own group.
    public var additionalTerms: [String]

    /// Whether filtering is applied at all. Off still leaves muting available.
    public var isFilterEnabled: Bool

    private let blockedTerms: [String]

    public init(additionalTerms: [String] = [], isFilterEnabled: Bool = true) {
        self.additionalTerms = additionalTerms
        self.isFilterEnabled = isFilterEnabled
        self.blockedTerms = (ChatModerator.defaultBlockedTerms + additionalTerms)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
            // Longest first, so "shut up" is masked as one phrase rather than
            // leaving "up" behind after "shut" is replaced.
            .sorted { $0.count > $1.count }
    }

    public struct Result: Hashable, Sendable {
        /// The text to display, with any matches masked.
        public var text: String
        /// Whether anything was masked.
        public var wasFiltered: Bool

        public init(text: String, wasFiltered: Bool) {
            self.text = text
            self.wasFiltered = wasFiltered
        }
    }

    /// Masks blocked terms with asterisks, preserving length so the shape of
    /// the message still reads.
    ///
    /// Matching is on whole words for single terms, so "class" is not mangled
    /// by a rule about a substring of it. Multi-word phrases are matched as
    /// written.
    public func filter(_ text: String) -> Result {
        guard isFilterEnabled, !text.isEmpty else {
            return Result(text: text, wasFiltered: false)
        }

        var output = text
        var didFilter = false

        for term in blockedTerms {
            var searchRange = output.startIndex..<output.endIndex
            while let found = output.range(of: term, options: [.caseInsensitive], range: searchRange) {
                if Self.isWholeWord(found, in: output) {
                    let mask = String(repeating: "*", count: output.distance(from: found.lowerBound, to: found.upperBound))
                    output.replaceSubrange(found, with: mask)
                    didFilter = true
                    // The mask is the same length, so resume just past it.
                    searchRange = output.index(found.lowerBound, offsetBy: mask.count)..<output.endIndex
                } else {
                    guard found.upperBound < output.endIndex else { break }
                    searchRange = found.upperBound..<output.endIndex
                }
            }
        }

        return Result(text: output, wasFiltered: didFilter)
    }

    /// True when the match is not embedded inside a larger word — which is
    /// what stops "assignment" tripping a rule about a substring of it.
    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
        }
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if isWordCharacter(before) { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if isWordCharacter(after) { return false }
        }
        return true
    }
}

// MARK: - Mute list

/// Who this device has chosen not to hear from.
///
/// Local and per-device on purpose. A mute is one player's preference, not a
/// moderation action taken against someone: it never leaves the iPad, the
/// muted player is not told, and nobody else's view changes. That makes it
/// safe to use — a child can mute someone they are sitting next to without it
/// becoming a social event.
public struct MuteList: Codable, Hashable, Sendable {
    private var muted: Set<PeerID>

    public init(muted: Set<PeerID> = []) {
        self.muted = muted
    }

    public var count: Int { muted.count }
    public var isEmpty: Bool { muted.isEmpty }
    public var all: Set<PeerID> { muted }

    public func isMuted(_ peer: PeerID) -> Bool {
        muted.contains(peer)
    }

    public mutating func mute(_ peer: PeerID) {
        muted.insert(peer)
    }

    public mutating func unmute(_ peer: PeerID) {
        muted.remove(peer)
    }

    @discardableResult
    public mutating func toggle(_ peer: PeerID) -> Bool {
        if muted.contains(peer) {
            muted.remove(peer)
            return false
        }
        muted.insert(peer)
        return true
    }

    public mutating func removeAll() {
        muted.removeAll()
    }

    /// Whether a message from `sender` should be shown.
    ///
    /// Your own messages are always shown: muting yourself is not a thing
    /// anyone means to do, and silently dropping your own chat would read as
    /// the app being broken.
    public func allows(_ sender: PeerID, localPeerID: PeerID) -> Bool {
        sender == localPeerID || !muted.contains(sender)
    }
}
