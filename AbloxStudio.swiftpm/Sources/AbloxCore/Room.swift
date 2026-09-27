import Foundation

// Everything about a room that is not the game itself: who is ready, the vote
// in progress, who the host has quieted, teams, whispers, asking to come in,
// being sent out, and handing the room to someone else when the host leaves.
// One packet kind (`PacketKind.room`) carries all of it.

// MARK: - Messages

public enum RoomMessage: Hashable, Sendable {
    // Guest → host.
    /// "I'm ready" in the waiting room, or not any more.
    case ready(Bool)
    /// A choice in the vote the host started.
    case vote(poll: UUID, choice: Int)
    /// A line for one player only. The host passes it on to them alone.
    case whisper(to: PeerID, text: String)

    // Host → guest.
    /// The room as it is now: sent to everyone whenever it changes.
    case state(RoomState)
    /// A whisper for this player, stamped by the host with who sent it.
    case whispered(from: PeerID, name: String, text: String)
    /// The host asks before anyone joins: wait for them to say yes.
    case waitingForHost
    /// The host said no.
    case refused
    /// The host took this player out of the room. They cannot come back
    /// into it until the host starts a new one.
    case removed
    /// The host is leaving and someone else is taking the room over.
    case moving(HostMove)
}

extension RoomMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, flag, poll, choice, peer, name, text, state, move
    }

    private enum Kind: String, Codable {
        case ready, vote, whisper, state, whispered, waitingForHost, refused, removed, moving
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ready(flag):
            try c.encode(Kind.ready, forKey: .type)
            try c.encode(flag, forKey: .flag)
        case let .vote(poll, choice):
            try c.encode(Kind.vote, forKey: .type)
            try c.encode(poll, forKey: .poll)
            try c.encode(choice, forKey: .choice)
        case let .whisper(to, text):
            try c.encode(Kind.whisper, forKey: .type)
            try c.encode(to, forKey: .peer)
            try c.encode(text, forKey: .text)
        case let .state(state):
            try c.encode(Kind.state, forKey: .type)
            try c.encode(state, forKey: .state)
        case let .whispered(from, name, text):
            try c.encode(Kind.whispered, forKey: .type)
            try c.encode(from, forKey: .peer)
            try c.encode(name, forKey: .name)
            try c.encode(text, forKey: .text)
        case .waitingForHost:
            try c.encode(Kind.waitingForHost, forKey: .type)
        case .refused:
            try c.encode(Kind.refused, forKey: .type)
        case .removed:
            try c.encode(Kind.removed, forKey: .type)
        case let .moving(move):
            try c.encode(Kind.moving, forKey: .type)
            try c.encode(move, forKey: .move)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .ready: self = .ready(try c.decode(Bool.self, forKey: .flag))
        case .vote: self = .vote(poll: try c.decode(UUID.self, forKey: .poll), choice: try c.decode(Int.self, forKey: .choice))
        case .whisper:
            self = .whisper(to: try c.decode(PeerID.self, forKey: .peer),
                            text: String(try c.decode(String.self, forKey: .text).prefix(AbloxProtocol.maxChatLength)))
        case .state: self = .state(try c.decode(RoomState.self, forKey: .state))
        case .whispered:
            self = .whispered(from: try c.decode(PeerID.self, forKey: .peer),
                              name: String(try c.decode(String.self, forKey: .name).prefix(AvatarProfile.maximumNameLength)),
                              text: String(try c.decode(String.self, forKey: .text).prefix(AbloxProtocol.maxChatLength)))
        case .waitingForHost: self = .waitingForHost
        case .refused: self = .refused
        case .removed: self = .removed
        case .moving: self = .moving(try c.decode(HostMove.self, forKey: .move))
        }
    }
}

// MARK: - The room

/// What the host tells everyone about the room.
public struct RoomState: Codable, Hashable, Sendable {
    /// Who has said they are ready in the waiting room.
    public var ready: Set<PeerID> = []
    /// The vote in progress, or the last one with its result.
    public var poll: Poll?
    /// Players the host has quieted: their chat and whispers go nowhere.
    public var quieted: Set<PeerID> = []
    /// Whether players may jump to a friend's side.
    public var allowsWarp = true
    /// Whether the host asks before anyone joins.
    public var needsApproval = false
    /// The host's clock when this was sent, so a guest can count down to
    /// the end of a vote on its own clock.
    public var clock: Double = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case ready, poll, quieted, allowsWarp, needsApproval, clock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ready = (try? c.decodeIfPresent(Set<PeerID>.self, forKey: .ready)) ?? []
        poll = try? c.decodeIfPresent(Poll.self, forKey: .poll)
        quieted = (try? c.decodeIfPresent(Set<PeerID>.self, forKey: .quieted)) ?? []
        allowsWarp = (try? c.decodeIfPresent(Bool.self, forKey: .allowsWarp)) ?? true
        needsApproval = (try? c.decodeIfPresent(Bool.self, forKey: .needsApproval)) ?? false
        clock = (try? c.decodeIfPresent(Double.self, forKey: .clock)) ?? 0
    }

    /// Seconds left in the vote, from the host's clock when this was sent.
    public var pollSecondsLeft: Double? {
        guard let poll, !poll.isClosed else { return nil }
        return max(0, poll.closesAt - clock)
    }

    /// How many of `people` are ready.
    public func readyCount(of people: [PeerID]) -> Int {
        people.filter { ready.contains($0) }.count
    }
}

// MARK: - Votes

/// A question with two to four answers, open for a little while.
public struct Poll: Codable, Hashable, Sendable, Identifiable {
    public static let maximumOptions = 4
    public static let maximumQuestionLength = 80
    public static let maximumOptionLength = 24
    public static let defaultSeconds: Double = 30

    public let id: UUID
    public let question: String
    public let options: [String]
    /// Each player's choice, by index into `options`.
    public private(set) var votes: [PeerID: Int] = [:]
    /// On the host's clock.
    public let closesAt: Double
    public private(set) var isClosed = false

    /// Nil when there are not two usable answers.
    public init?(question: String, options: [String], closesAt: Double, id: UUID = UUID()) {
        let answers = options
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumOptionLength)) }
            .filter { !$0.isEmpty }
        let asked = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumQuestionLength))
        guard !asked.isEmpty, (2...Self.maximumOptions).contains(answers.count) else { return nil }
        self.id = id
        self.question = asked
        self.options = answers
        self.closesAt = closesAt
    }

    /// Records a choice; a second vote replaces the first. False when the
    /// vote is over or the choice is not one of the answers.
    @discardableResult
    public mutating func vote(_ peer: PeerID, choice: Int) -> Bool {
        guard !isClosed, options.indices.contains(choice) else { return false }
        votes[peer] = choice
        return true
    }

    /// Closes the vote once its time is up. True when this call closed it.
    public mutating func closeIfDue(at time: Double) -> Bool {
        guard !isClosed, time >= closesAt else { return false }
        isClosed = true
        return true
    }

    public mutating func close() {
        isClosed = true
    }

    /// Votes for each answer, in order.
    public var tally: [Int] {
        options.indices.map { index in votes.values.filter { $0 == index }.count }
    }

    /// The answer with the most votes, or nil with no votes or a tie.
    public var winner: Int? {
        let counts = tally
        guard let best = counts.max(), best > 0, counts.filter({ $0 == best }).count == 1 else { return nil }
        return counts.firstIndex(of: best)
    }

    /// Ready-made questions for the host's menu, in English (shown through `L`).
    public static let presets: [(question: String, options: [String])] = [
        ("Play again?", ["Yes", "No"]),
        ("Keep going or change game?", ["Keep going", "Change game"]),
        ("New teams?", ["Yes", "No"]),
        ("Which is best?", ["Red", "Blue", "Green", "Yellow"])
    ]
}

// MARK: - Teams

public enum TeamPicker {
    /// Team names in the order they are used, in English (shown through `L`).
    public static let names = ["Red", "Blue", "Green", "Yellow"]
    public static let colorHexes = ["#EF4444", "#3B82F6", "#22C55E", "#FACC15"]

    /// Everyone shuffled into `count` teams, as evenly as can be.
    public static func shuffled(_ players: [PeerID], teams count: Int, seed: UInt64) -> [PeerID: String] {
        let teams = Array(names.prefix(max(2, min(names.count, count))))
        var random = ScriptRandom(seed: seed)
        var order = players
        // Fisher–Yates with the game's own seeded generator, so a test can
        // say exactly who lands where.
        if order.count > 1 {
            for i in stride(from: order.count - 1, to: 0, by: -1) {
                let j = random.integer(0, i)
                order.swapAt(i, j)
            }
        }
        var result: [PeerID: String] = [:]
        for (index, peer) in order.enumerated() {
            result[peer] = teams[index % teams.count]
        }
        return result
    }

    /// The next team when the host taps a player: no team, then each team in
    /// turn, then no team again.
    public static func next(after team: String, teams count: Int) -> String {
        let teams = Array(names.prefix(max(2, min(names.count, count))))
        guard let index = teams.firstIndex(of: team) else { return teams[0] }
        return index + 1 < teams.count ? teams[index + 1] : ""
    }

    public static func colorHex(for team: String) -> String? {
        names.firstIndex(of: team).map { colorHexes[$0] }
    }
}

// MARK: - Handing over

/// Where the room goes when its host leaves: to another player's iPad, with
/// the same code, so everyone else can follow.
public struct HostMove: Codable, Hashable, Sendable {
    public var newHost: PeerID
    public var newHostName: String
    public var roomCode: String
    public var isPublic: Bool
    public var capacity: Int
    public var needsApproval: Bool
    /// Everyone in the room when it moved: let straight back in even when
    /// the new host asks before anyone joins.
    public var members: [PeerID]

    public init(newHost: PeerID, newHostName: String, roomCode: String, isPublic: Bool, capacity: Int, needsApproval: Bool,
                members: [PeerID] = []) {
        self.newHost = newHost
        self.newHostName = String(newHostName.prefix(AvatarProfile.maximumNameLength))
        self.roomCode = roomCode
        self.isPublic = isPublic
        self.capacity = capacity
        self.needsApproval = needsApproval
        self.members = Array(members.prefix(64))
    }

    private enum CodingKeys: String, CodingKey {
        case newHost, newHostName, roomCode, isPublic, capacity, needsApproval, members
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(newHost: try c.decode(PeerID.self, forKey: .newHost),
                  newHostName: try c.decode(String.self, forKey: .newHostName),
                  roomCode: try c.decode(String.self, forKey: .roomCode),
                  isPublic: try c.decode(Bool.self, forKey: .isPublic),
                  capacity: try c.decode(Int.self, forKey: .capacity),
                  needsApproval: try c.decode(Bool.self, forKey: .needsApproval),
                  members: (try? c.decodeIfPresent([PeerID].self, forKey: .members)) ?? [])
    }

    /// Who takes over: whoever has been in the room longest, never a
    /// character a script made.
    public static func successor(in roster: [PlayerSnapshot], leavingHost: PeerID) -> PlayerSnapshot? {
        roster.first { !$0.isNPC && $0.peerID != leavingHost }
    }
}

// MARK: - Who is in a room, from outside

/// A short piece of each player's id, in the room's advertisement, so the
/// Play list can say "your friend is in here" — or "someone you blocked is"
/// — before anyone joins. Eight hex digits: enough to recognise a friend,
/// not the whole id.
public struct RoomTag: Hashable, Sendable {
    public static let length = 8
    public static let maximumPlayers = 24

    public let shortIDs: Set<String>

    public init(players: [PeerID]) {
        shortIDs = Set(players.prefix(Self.maximumPlayers).map(Self.short))
    }

    /// Reads the advertised form; anything that is not a short id is dropped.
    public init(text: String) {
        let parts = text.split(separator: ",").map { $0.lowercased() }
        shortIDs = Set(parts.prefix(Self.maximumPlayers).filter { part in
            part.count == Self.length && part.allSatisfy { $0.isHexDigit }
        })
    }

    public var text: String {
        shortIDs.sorted().joined(separator: ",")
    }

    public func contains(_ peer: PeerID) -> Bool {
        shortIDs.contains(Self.short(peer))
    }

    public static func short(_ peer: PeerID) -> String {
        String(peer.raw.uuidString.replacingOccurrences(of: "-", with: "").prefix(length)).lowercased()
    }
}

// MARK: - Joining without the list

/// Everything needed to join a room without finding it in the list: where
/// it is, its code and its salt. Shown by the host as a QR code, or sent as
/// text — for iPads that cannot see each other's rooms, such as on a school
/// network that blocks the list, or over a VPN.
///
/// It is not a way to play over the internet: the host's iPad still has to
/// be reachable at that address, which a home router does not allow from
/// outside without a server in between.
public struct JoinTicket: Hashable, Sendable, Identifiable {
    public static let scheme = "ablox:join"

    public var host: String
    public var port: UInt16
    public var salt: String
    public var code: String
    public var world: String

    public var id: String { text }

    public init?(host: String, port: UInt16, salt: String, code: String, world: String) {
        let code = RoomCodeFormat.normalize(code)
        guard Self.isPlausibleHost(host), port > 0, Self.isPlausibleSalt(salt), RoomCodeFormat.isPlausible(code) else { return nil }
        self.host = host
        self.port = port
        self.salt = salt.lowercased()
        self.code = code
        self.world = String(world.prefix(60))
    }

    /// Reads `ablox:join?h=…&p=…&s=…&c=…&w=…`, as the QR code carries it.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(Self.scheme + "?"),
              let components = URLComponents(string: "x://y?" + trimmed.dropFirst(Self.scheme.count + 1)) else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
        guard let host = values["h"], let port = values["p"].flatMap(UInt16.init),
              let salt = values["s"], let code = values["c"] else { return nil }
        self.init(host: host, port: port, salt: salt, code: code, world: values["w"] ?? "")
    }

    public var text: String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "c", value: code),
            URLQueryItem(name: "w", value: world)
        ]
        return Self.scheme + "?" + (components.percentEncodedQuery ?? "")
    }

    /// An IPv4 or IPv6 address, or a `.local` name.
    public static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:-%").union(.alphanumerics)
        return host.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    static func isPlausibleSalt(_ salt: String) -> Bool {
        (8...64).contains(salt.count) && salt.allSatisfy { $0.isHexDigit }
    }
}
