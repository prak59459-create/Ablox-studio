import Foundation

// The people a player has met: friends, everyone played with lately, those
// they have blocked, and reports kept for a grown-up to read. All on this
// iPad — there is no account and no server, so a friend is "someone this
// iPad has played with and chose to remember", recognised by their player id.

/// Someone met in a game.
public struct PlayerContact: Codable, Hashable, Sendable, Identifiable {
    public var id: PeerID
    public var name: String
    public var lastSeen: Date
    /// The game they were last seen in.
    public var lastGame: String
    /// Separate visits, not roster updates.
    public var timesMet: Int
    /// What this player calls them ("Taro from school"). Only on this iPad;
    /// their own name still shows beside it.
    public var nickname: String?
    /// Pinned to the top of the list.
    public var favourite: Bool?
    /// A few words to remember them by.
    public var note: String?
    /// A `FriendGroup` by name; kept as text so a group from a newer
    /// version never makes the whole list unreadable.
    public var groupName: String?
    /// When they became a friend.
    public var friendSince: Date?

    /// The nickname when there is one, otherwise their own name.
    public var shownName: String {
        guard let nickname, !nickname.isEmpty else { return name }
        return nickname
    }

    public init(id: PeerID, name: String, lastSeen: Date = Date(), lastGame: String = "", timesMet: Int = 1) {
        self.id = id
        self.name = String(name.prefix(AvatarProfile.maximumNameLength))
        self.lastSeen = lastSeen
        self.lastGame = String(lastGame.prefix(60))
        self.timesMet = timesMet
    }
}

/// Friends, people played with lately, and people blocked.
public struct SocialBook: Codable, Hashable, Sendable {
    public private(set) var friends: [PlayerContact] = []
    /// Newest first.
    public private(set) var recent: [PlayerContact] = []
    public private(set) var blocked: [PlayerContact] = []

    public static let keptRecent = 40
    public static let maximumFriends = 100
    /// Seeing someone again after this long counts as meeting them again.
    public static let newVisitAfter: TimeInterval = 30 * 60

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        friends = (try? c.decodeIfPresent([PlayerContact].self, forKey: .friends)) ?? []
        recent = (try? c.decodeIfPresent([PlayerContact].self, forKey: .recent)) ?? []
        blocked = (try? c.decodeIfPresent([PlayerContact].self, forKey: .blocked)) ?? []
    }

    public func isFriend(_ id: PeerID) -> Bool { friends.contains { $0.id == id } }
    public func isBlocked(_ id: PeerID) -> Bool { blocked.contains { $0.id == id } }

    /// Everyone in a game right now: remembered as played with, and a
    /// friend's name and last sighting kept up to date. Characters a script
    /// made and this iPad's own player are left out.
    public mutating func met(_ players: [PlayerSnapshot], game: String, localPeerID: PeerID, at date: Date = Date()) {
        for player in players where !player.isNPC && player.peerID != localPeerID {
            let name = player.profile.displayName
            if let index = recent.firstIndex(where: { $0.id == player.peerID }) {
                var contact = recent.remove(at: index)
                if date.timeIntervalSince(contact.lastSeen) >= Self.newVisitAfter { contact.timesMet += 1 }
                contact.name = String(name.prefix(AvatarProfile.maximumNameLength))
                contact.lastSeen = date
                contact.lastGame = String(game.prefix(60))
                recent.insert(contact, at: 0)
            } else {
                recent.insert(PlayerContact(id: player.peerID, name: name, lastSeen: date, lastGame: game), at: 0)
            }
            if let index = friends.firstIndex(where: { $0.id == player.peerID }) {
                friends[index].name = String(name.prefix(AvatarProfile.maximumNameLength))
                friends[index].lastSeen = date
                friends[index].lastGame = String(game.prefix(60))
            }
        }
        if recent.count > Self.keptRecent { recent.removeLast(recent.count - Self.keptRecent) }
    }

    /// False when the list is full or they are blocked.
    @discardableResult
    public mutating func addFriend(_ id: PeerID, name: String, at date: Date = Date()) -> Bool {
        guard !isBlocked(id), friends.count < Self.maximumFriends else { return false }
        guard !isFriend(id) else { return true }
        var friend = recent.first { $0.id == id } ?? PlayerContact(id: id, name: name, lastSeen: date)
        friend.friendSince = date
        friends.append(friend)
        friends.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return true
    }

    public mutating func removeFriend(_ id: PeerID) {
        friends.removeAll { $0.id == id }
    }

    public static let maximumNicknameLength = 24

    /// A friend's nickname on this iPad; empty clears it. Kept when they
    /// change their own name.
    public mutating func setNickname(_ nickname: String, for id: PeerID) {
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNicknameLength))
        friends[index].nickname = trimmed.isEmpty ? nil : trimmed
    }

    /// Pins a friend to the top of the list, or unpins them.
    public mutating func setFavourite(_ favourite: Bool, for id: PeerID) {
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[index].favourite = favourite ? true : nil
    }

    /// A note about a friend; empty clears it.
    public mutating func setNote(_ note: String, for id: PeerID) {
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNoteLength))
        friends[index].note = trimmed.isEmpty ? nil : trimmed
    }

    /// Which group a friend is in, or none.
    public mutating func setGroup(_ group: FriendGroup?, for id: PeerID) {
        guard let index = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[index].group = group
    }

    /// Blocking also ends a friendship: the two do not go together.
    public mutating func block(_ id: PeerID, name: String, at date: Date = Date()) {
        removeFriend(id)
        guard !isBlocked(id) else { return }
        blocked.append(PlayerContact(id: id, name: name, lastSeen: date))
    }

    public mutating func unblock(_ id: PeerID) {
        blocked.removeAll { $0.id == id }
    }

    public mutating func forgetRecent() {
        recent.removeAll()
    }

    /// Friends in a room, from what the room advertises.
    public func friends(in room: RoomTag) -> [PlayerContact] {
        friends.filter { room.contains($0.id) }
    }

    /// People this player blocked who are in a room.
    public func blocked(in room: RoomTag) -> [PlayerContact] {
        blocked.filter { room.contains($0.id) }
    }
}

// MARK: - Reports

/// Something a player wanted a grown-up to know about, kept on this iPad
/// with what was said and a picture of the moment. Nothing is sent anywhere;
/// Settings → Family lists them, and a parent can share one from there.
public struct PlayerReport: Codable, Hashable, Sendable, Identifiable {
    public enum Reason: String, Codable, CaseIterable, Sendable {
        case rudeWords, unkind, askedPersonal, cheating, other

        public var displayName: String {
            switch self {
            case .rudeWords: return L("Rude or bad words")
            case .unkind: return L("Being mean or bullying")
            case .askedPersonal: return L("Asked where I live, my school or my real name")
            case .cheating: return L("Cheating or spoiling the game")
            case .other: return L("Something else")
            }
        }
    }

    public static let keptChatLines = 30
    public static let maximumNoteLength = 400

    public let id: UUID
    public let date: Date
    public let playerID: PeerID
    public let playerName: String
    public let game: String
    public let reason: Reason
    public let note: String
    /// The room's recent chat, "Name: line", oldest first.
    public let chat: [String]
    /// The picture's file name beside the report, if one was taken.
    public var picture: String?

    public init(id: UUID = UUID(), date: Date = Date(), playerID: PeerID, playerName: String, game: String,
                reason: Reason, note: String, chat: [String], picture: String? = nil) {
        self.id = id
        self.date = date
        self.playerID = playerID
        self.playerName = String(playerName.prefix(AvatarProfile.maximumNameLength))
        self.game = String(game.prefix(60))
        self.reason = reason
        self.note = String(note.prefix(Self.maximumNoteLength))
        self.chat = Array(chat.suffix(Self.keptChatLines))
        self.picture = picture
    }

    /// The report as plain text, for sharing with someone who can help.
    public var summary: String {
        var lines = [
            L("Ablox report"),
            L("When: {}", date.formatted(date: .abbreviated, time: .shortened)),
            L("Player: {} ({})", playerName, RoomTag.short(playerID)),
            L("Game: {}", game),
            L("What happened: {}", reason.displayName)
        ]
        if !note.isEmpty { lines.append(L("Note: {}", note)) }
        if !chat.isEmpty {
            lines.append("")
            lines.append(L("Chat before the report:"))
            lines.append(contentsOf: chat)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Whispers

public enum Whisper {
    /// Whispers need full chat: a child limited to ready-made phrases, or
    /// with chat off, neither sends nor receives private lines.
    public static func isAllowed(_ chat: ChatAllowance) -> Bool {
        chat == .full
    }
}
