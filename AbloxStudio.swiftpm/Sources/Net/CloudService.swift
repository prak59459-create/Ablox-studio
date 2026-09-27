import Foundation
import Combine
import AbloxCore

/// A friend over the internet: added by friend code, and a friend once both
/// have added each other. Until then their profile cannot be read (the
/// database's rules), so all that is known is how they were added.
public struct CloudFriend: Identifiable, Hashable, Sendable {
    public var id: String
    /// Their name when known, or the friend code they were added by.
    public var label: String
    public var profile: CloudProfile?
    public var hasUnread: Bool

    public var isMutual: Bool { profile != nil }
}

public struct CloudRequest: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
}

/// Everything Ablox does with the family's Firebase database: signing in,
/// the friend code, friends and their profiles, requests, chat, the list of
/// internet rooms, and opening or joining one.
///
/// Off unless Settings → Family → Internet allows it. Nothing is sent before
/// then — not even a sign-in.
@MainActor
public final class CloudService: ObservableObject {

    public enum State: Equatable {
        case off
        case connecting
        case ready
        case failed(String)
    }

    @Published public private(set) var state: State = .off
    @Published public private(set) var uid: String?
    @Published public private(set) var friendCode: String?
    @Published public private(set) var friends: [CloudFriend] = []
    @Published public private(set) var requests: [CloudRequest] = []
    @Published public private(set) var rooms: [CloudRoom] = []
    /// The chat that is open, oldest first.
    @Published public private(set) var messages: [CloudMessage] = []
    @Published public private(set) var chattingWith: String?
    /// The internet room this iPad is hosting.
    @Published public private(set) var hostedRoom: String?

    private var settings = CloudSettings()
    private var profile = AvatarProfile.default
    private var database: CloudDatabase?
    private var tasks: [Task<Void, Never>] = []
    private var chatTask: Task<Void, Never>?
    private var hostTask: Task<Void, Never>?
    private var relayHost: CloudRelayHost?
    private var relayGuest: CloudRelayGuest?
    private var added: Set<String> = []
    private var game: String?
    private var room: String?
    private var roleWatch: AnyCancellable?
    private var restartTask: Task<Void, Never>?
    public var moderator = ChatModerator()

    private let defaults: UserDefaults
    private var names: [String: String] {
        get { defaults.dictionary(forKey: "ablox.cloud.names") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "ablox.cloud.names") }
    }
    /// The newest message key read in each chat.
    private var lastRead: [String: String] {
        get { defaults.dictionary(forKey: "ablox.cloud.read") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "ablox.cloud.read") }
    }
    public private(set) var blocked: Set<String> {
        get { Set(defaults.stringArray(forKey: "ablox.cloud.blocked") ?? []) }
        set { defaults.set(Array(newValue), forKey: "ablox.cloud.blocked") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isReady: Bool { state == .ready }
    public var allowsFriends: Bool { settings.allowFriends }
    public var allowsChat: Bool { settings.allowFriends && settings.allowFriendChat }
    public var allowsInternetPlay: Bool { settings.allowInternetPlay && settings.config.isUsable }

    // MARK: Switching on and off

    /// Applies Settings → Family → Internet, and the player's look.
    public func configure(_ settings: CloudSettings, profile: AvatarProfile) {
        let restart = settings.config != self.settings.config || settings.isActive != self.settings.isActive
            || settings.allowFriends != self.settings.allowFriends
        let shareChanged = settings.shareWhatIPlay != self.settings.shareWhatIPlay
        self.settings = settings
        let lookChanged = profile != self.profile
        self.profile = profile
        if restart {
            // A moment's wait, so typing a key in does not sign in at
            // every letter.
            restartTask?.cancel()
            restartTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self.stop()
                if self.settings.isActive { self.start() }
            }
        } else if lookChanged || shareChanged, state == .ready {
            Task { await publishProfile(online: true) }
        }
    }

    private func start() {
        guard let database = CloudDatabase(auth: CloudAuth(config: settings.config)) else {
            state = .failed(CloudError.notConfigured.localizedDescription)
            return
        }
        self.database = database
        state = .connecting
        tasks.append(Task { await self.run(database) })
    }

    public func stop() {
        if let database, let uid, state == .ready, settings.allowFriends {
            let offline = JSONValue.object(["online": .bool(false), "seen": .serverTime])
            Task { try? await database.update(CloudPath.profile(uid), offline.object ?? [:]) }
        }
        stopHosting()
        leaveRoom()
        closeChat()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        database = nil
        state = .off
        friends = []
        requests = []
        rooms = []
    }

    private func run(_ database: CloudDatabase) async {
        do {
            let uid = try await database.auth.signIn()
            self.uid = uid
            if settings.allowFriends {
                friendCode = try await claimFriendCode(database, uid: uid)
                await publishProfile(online: true)
                tasks.append(Task { await self.watchFriends(database, uid: uid) })
                tasks.append(Task { await self.watchRequests(database, uid: uid) })
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        // Every twenty seconds: still here, friends' news, the rooms.
        while !Task.isCancelled {
            if settings.allowFriends {
                await publishProfile(online: true)
                await refreshFriends(database)
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    // MARK: The friend code

    private func claimFriendCode(_ database: CloudDatabase, uid: String) async throws -> String {
        let key = "ablox.cloud.code." + uid
        if let saved = defaults.string(forKey: key) { return saved }
        for _ in 0..<6 {
            let code = CloudIDs.newFriendCode()
            if case .null = try await database.get(CloudPath.friendCode(code)) {
                do {
                    try await database.put(CloudPath.friendCode(code), .string(uid))
                    defaults.set(code, forKey: key)
                    return code
                } catch CloudError.denied {
                    continue    // taken in the moment between looking and claiming
                }
            }
        }
        throw CloudError.badResponse
    }

    // MARK: This iPad's profile

    /// What friends see: the look, whether this iPad is on, and — if the
    /// family allows it — the game and the internet room it is in.
    private func publishProfile(online: Bool) async {
        guard let database, let uid, let friendCode, settings.allowFriends else { return }
        var mine = CloudProfile(avatar: profile.sanitizedForNetwork(), code: friendCode, online: online)
        if settings.shareWhatIPlay {
            mine.game = game
            mine.room = room
        }
        guard let value = JSONValue.encoding(mine)?.with("seen", .serverTime) else { return }
        try? await database.put(CloudPath.profile(uid), value)
    }

    /// What this iPad is playing now, for friends to see and join.
    public func setPlaying(game: String?, room: String?) {
        guard game != self.game || room != self.room else { return }
        self.game = game.map { String($0.prefix(60)) }
        self.room = room
        Task { await publishProfile(online: true) }
    }

    // MARK: Friends

    private func watchFriends(_ database: CloudDatabase, uid: String) async {
        var mirror = CloudMirror()
        for await event in database.stream(CloudPath.friends(of: uid)) {
            mirror.apply(event)
            added = Set((mirror.value.object ?? [:]).keys.filter(CloudPath.isSafeKey))
            await refreshFriends(database)
        }
    }

    private func watchRequests(_ database: CloudDatabase, uid: String) async {
        var mirror = CloudMirror()
        for await event in database.stream(CloudPath.requests(to: uid)) {
            mirror.apply(event)
            let blocked = self.blocked
            requests = (mirror.value.object ?? [:]).compactMap { key, value in
                guard CloudPath.isSafeKey(key), !blocked.contains(key), !added.contains(key),
                      let request = value.decode(CloudFriendRequest.self) else { return nil }
                return CloudRequest(id: key, name: moderator.cleanName(String(request.name.prefix(24))))
            }
            .sorted { $0.name < $1.name }
        }
    }

    /// Each friend's profile (readable once they have added this iPad too)
    /// and whether their chat has something new.
    private func refreshFriends(_ database: CloudDatabase) async {
        guard let uid else { return }
        var list: [CloudFriend] = []
        var names = self.names
        let read = lastRead
        for other in added.sorted() {
            var friend = CloudFriend(id: other, label: names[other] ?? other, profile: nil, hasUnread: false)
            if let value = try? await database.get(CloudPath.profile(other)), value != .null,
               let profile = value.decode(CloudProfile.self)?.cleaned {
                friend.profile = profile
                friend.label = profile.avatar.displayName
                names[other] = profile.avatar.displayName
                if allowsChat, other != chattingWith,
                   let newest = try? await database.get(CloudPath.chat(CloudIDs.pair(uid, other)),
                                                        query: [URLQueryItem(name: "orderBy", value: "\"$key\""),
                                                                URLQueryItem(name: "limitToLast", value: "1")]),
                   let key = newest.object?.keys.first,
                   newest[key]["from"].string == other {
                    friend.hasUnread = key > (read[other] ?? "")
                }
            }
            list.append(friend)
        }
        self.names = names
        let now = Date().timeIntervalSince1970 * 1000
        friends = list.sorted { a, b in
            let aOn = a.profile?.isOnline(now: now) ?? false
            let bOn = b.profile?.isOnline(now: now) ?? false
            if aOn != bOn { return aOn }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    /// Adds someone by their friend code. Returns what went wrong, if anything.
    public func addFriend(code text: String) async -> String? {
        guard let database, let uid else { return L("Not connected to the internet yet.") }
        guard let code = CloudIDs.normalizeFriendCode(text) else { return L("A friend code is eight letters and numbers, like ABCD-2345.") }
        guard code != friendCode else { return L("That's your own friend code.") }
        do {
            guard let other = try await database.get(CloudPath.friendCode(code)).string, CloudPath.isSafeKey(other) else {
                return L("Nobody has that friend code.")
            }
            guard !added.contains(other) else { return L("You've already added them.") }
            try await database.put(CloudPath.request(to: other, from: uid),
                                   .object(["name": .string(profile.sanitizedForNetwork().displayName), "at": .serverTime]))
            try await database.put(CloudPath.friend(of: uid, other), .bool(true))
            var names = self.names
            names[other] = CloudIDs.displayFriendCode(code)
            self.names = names
            var unblocked = blocked
            unblocked.remove(other)
            blocked = unblocked
            await refreshFriends(database)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func accept(_ request: CloudRequest) {
        guard let database, let uid else { return }
        var names = self.names
        names[request.id] = request.name
        self.names = names
        requests.removeAll { $0.id == request.id }
        Task {
            try? await database.put(CloudPath.friend(of: uid, request.id), .bool(true))
            try? await database.delete(CloudPath.request(to: uid, from: request.id))
            await refreshFriends(database)
        }
    }

    public func decline(_ request: CloudRequest) {
        guard let database, let uid else { return }
        requests.removeAll { $0.id == request.id }
        Task { try? await database.delete(CloudPath.request(to: uid, from: request.id)) }
    }

    public func remove(_ friend: CloudFriend) {
        guard let database, let uid else { return }
        friends.removeAll { $0.id == friend.id }
        Task { try? await database.delete(CloudPath.friend(of: uid, friend.id)) }
    }

    /// Removes them, and ignores their requests from now on.
    public func block(_ id: String) {
        var list = blocked
        list.insert(id)
        blocked = list
        if let friend = friends.first(where: { $0.id == id }) { remove(friend) }
        if let request = requests.first(where: { $0.id == id }) { decline(request) }
    }

    // MARK: Chat

    public func openChat(with friend: CloudFriend) {
        guard allowsChat, let database, let uid, friend.isMutual else { return }
        closeChat()
        chattingWith = friend.id
        messages = []
        let pair = CloudIDs.pair(uid, friend.id)
        chatTask = Task {
            var mirror = CloudMirror()
            for await event in database.stream(CloudPath.chat(pair)) {
                mirror.apply(event)
                let all = (mirror.value.object ?? [:]).compactMap { key, value -> CloudMessage? in
                    guard var message = value.decode(CloudMessage.self), message.from == uid || message.from == friend.id else { return nil }
                    message.id = key
                    // Both ends filter: what arrives is filtered here as well.
                    message.text = moderator.filter(message.text).text
                    return message
                }
                .sorted { $0.id < $1.id }
                messages = Array(all.suffix(CloudMessage.keptMessages))
                if let newest = all.last {
                    var read = lastRead
                    read[friend.id] = newest.id
                    lastRead = read
                    if let index = friends.firstIndex(where: { $0.id == friend.id }) { friends[index].hasUnread = false }
                }
                // Whoever is here keeps the chat short.
                if all.count > CloudMessage.keptMessages {
                    var removals: [String: JSONValue] = [:]
                    for old in all.prefix(all.count - CloudMessage.keptMessages) where old.from == uid { removals[old.id] = .null }
                    if !removals.isEmpty { try? await database.update(CloudPath.chat(pair), removals) }
                }
            }
        }
    }

    public func closeChat() {
        chatTask?.cancel()
        chatTask = nil
        chattingWith = nil
        messages = []
    }

    /// Sends a line to the open chat. Returns what went wrong, if anything.
    public func send(_ text: String) async -> String? {
        guard allowsChat, let database, let uid, let other = chattingWith else { return L("Chat is turned off.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clean = moderator.filter(String(trimmed.prefix(CloudMessage.maximumLength))).text
        do {
            _ = try await database.add(CloudPath.chat(CloudIDs.pair(uid, other)),
                                       .object(["from": .string(uid), "text": .string(clean), "at": .serverTime]))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Internet rooms

    /// The rooms open now, newest first.
    public func refreshRooms() async {
        guard allowsInternetPlay, let database else { return }
        let query = [URLQueryItem(name: "orderBy", value: "\"at\""), URLQueryItem(name: "limitToLast", value: "40")]
        guard let value = try? await database.get(CloudPath.lobby, query: query) else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let blocked = self.blocked
        rooms = (value.object ?? [:]).compactMap { key, entry -> CloudRoom? in
            guard CloudPath.isSafeKey(key), var room = entry.decode(CloudRoom.self), room.isFresh(now: now),
                  room.host != uid, !blocked.contains(room.host) else { return nil }
            room.id = key
            room.hostName = moderator.cleanName(room.hostName)
            room.world = moderator.cleanName(room.world)
            return room
        }
        .sorted { $0.at > $1.at }
    }

    /// Puts the room this iPad is hosting on the internet: in the list, and
    /// reachable through the relay. Waits for the room to be open first.
    public func hostRoom(session: SessionCoordinator) {
        guard allowsInternetPlay else { return }
        stopHosting()
        hostTask = Task {
            // The listener takes a moment (and a game may fetch its scripts first).
            var keys = session.roomKeys
            var waited = 0
            while keys == nil || uid == nil, waited < 120, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 1
                keys = session.roomKeys
            }
            guard let keys, let database, let uid else { return }
            let key = CloudIDs.newLinkID()
            @MainActor func entry() -> JSONValue? {
                let room = CloudRoom(host: uid, hostName: profile.sanitizedForNetwork().displayName, world: session.world.name,
                                     worldID: session.world.id.uuidString, players: max(1, session.people.count),
                                     capacity: keys.capacity, code: keys.code, salt: keys.salt)
                return JSONValue.encoding(room)?.with("at", .serverTime)
            }
            guard let first = entry() else { return }
            do {
                try await database.put(CloudPath.room(key), first)
            } catch {
                session.noteCloudProblem(error.localizedDescription)
                return
            }
            let relay = CloudRelayHost(database: database, room: key, localPort: keys.port)
            relay.start()
            relayHost = relay
            hostedRoom = key
            setPlaying(game: session.world.name, room: key)
            watchRole(session)
            // Still here, and how full.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                if let update = entry() { try? await database.put(CloudPath.room(key), update) }
            }
        }
    }

    public func stopHosting() {
        hostTask?.cancel()
        hostTask = nil
        relayHost?.stop()
        relayHost = nil
        if let key = hostedRoom, let database {
            // The relay goes first: the rules let the host clear it only
            // while its room is still listed.
            Task {
                try? await database.delete(CloudPath.relay(key))
                try? await database.delete(CloudPath.room(key))
            }
        }
        if hostedRoom != nil { setPlaying(game: nil, room: nil) }
        hostedRoom = nil
    }

    /// Joins an internet room through the relay.
    public func join(_ room: CloudRoom, session: SessionCoordinator) async {
        guard allowsInternetPlay, let database else { return }
        leaveRoom()
        let guest = CloudRelayGuest(database: database, room: room.id)
        do {
            let port = try await guest.start()
            guard let ticket = room.ticket(localPort: port) else { throw CloudError.badResponse }
            relayGuest = guest
            session.join(ticket: ticket)
            setPlaying(game: room.world, room: room.id)
            watchRole(session)
        } catch {
            guest.stop()
            session.noteCloudProblem(error.localizedDescription)
        }
    }

    /// Joins the internet room a friend is in.
    public func join(friend: CloudFriend, session: SessionCoordinator) async -> Bool {
        guard let key = friend.profile?.room else { return false }
        if !rooms.contains(where: { $0.id == key }) { await refreshRooms() }
        guard let room = rooms.first(where: { $0.id == key }) else { return false }
        await join(room, session: session)
        return true
    }

    public func leaveRoom() {
        relayGuest?.stop()
        if relayGuest != nil { setPlaying(game: nil, room: nil) }
        relayGuest = nil
    }

    /// Stops hosting or leaves the relay when the game ends.
    private func watchRole(_ session: SessionCoordinator) {
        roleWatch = session.$role
            .dropFirst()
            .filter { $0 == .offline }
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.stopHosting()
                    self?.leaveRoom()
                    self?.roleWatch = nil
                }
            }
    }
}
