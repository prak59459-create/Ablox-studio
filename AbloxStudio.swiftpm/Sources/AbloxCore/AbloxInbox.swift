import Foundation

/// Notifications from Ablox (8.8), behind the bell at the top of the menu: a
/// new version, news from `notices.json`, a friend request, a friend playing
/// in an internet room (an invitation to join), a friend's new message, and
/// a friend who has started playing nearby.
///
/// Everything here was already somewhere in the app, in a banner or a list;
/// a suggestion asked for one place that says so, with a count of what is
/// new. With Settings → Notifications on, each new one is also an iPad
/// notification (`InboxNotifier`), while Ablox is open.
///
/// Worked out from what the app already knows, never stored: an item is
/// there while its cause is (the update not yet installed, the request not
/// yet answered). Only the ids that have been seen are kept, so the count
/// shows what is new.
public struct InboxItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case update, notice, friendRequest, friendRoom, friendMessage, friendNearby
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String

    public init(id: String, kind: Kind, title: String, body: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
    }
}

public enum AbloxInbox {

    /// What the app knows now, gathered by the menu.
    public struct Sources: Sendable {
        /// The newer version on offer, if any, and whether it is needed to
        /// play with friends who have it.
        public var update: (version: AppVersion, required: Bool)?
        public var notices: [AppNotice]
        /// Friend requests: who asked, by id and name.
        public var requests: [(id: String, name: String)]
        /// Internet rooms hosted by a friend.
        public var friendRooms: [(id: String, host: String, world: String)]
        /// Friends with a message not read yet.
        public var unread: [(id: String, name: String)]
        /// A friend who has started playing nearby.
        public var nearby: (name: String, world: String)?

        public init(update: (version: AppVersion, required: Bool)? = nil, notices: [AppNotice] = [],
                    requests: [(id: String, name: String)] = [], friendRooms: [(id: String, host: String, world: String)] = [],
                    unread: [(id: String, name: String)] = [], nearby: (name: String, world: String)? = nil) {
            self.update = update
            self.notices = notices
            self.requests = requests
            self.friendRooms = friendRooms
            self.unread = unread
            self.nearby = nearby
        }
    }

    /// The most kept in the list of seen ids.
    public static let keptSeen = 200

    /// The notifications, newest kinds first: friends, then the update, then news.
    public static func items(_ sources: Sources, language: Language) -> [InboxItem] {
        var items: [InboxItem] = []
        if let nearby = sources.nearby {
            items.append(InboxItem(id: "nearby:\(nearby.name):\(nearby.world)", kind: .friendNearby,
                                   title: L("{} is playing nearby", nearby.name),
                                   body: L("{} — join from the banner, or Play → Rooms.", nearby.world)))
        }
        for room in sources.friendRooms {
            items.append(InboxItem(id: "room:\(room.id)", kind: .friendRoom,
                                   title: L("{} invites you to play", room.host),
                                   body: L("{} — join from Play → Rooms.", room.world)))
        }
        for request in sources.requests {
            items.append(InboxItem(id: "request:\(request.id)", kind: .friendRequest,
                                   title: L("Friend request from {}", request.name),
                                   body: L("Answer it in Play → Rooms → Friends.")))
        }
        for friend in sources.unread {
            items.append(InboxItem(id: "message:\(friend.id)", kind: .friendMessage,
                                   title: L("New message from {}", friend.name),
                                   body: L("Read it in Play → Rooms → Friends.")))
        }
        if let update = sources.update {
            items.append(InboxItem(id: "update:\(update.version)", kind: .update,
                                   title: L("Ablox {} is ready", update.version.description),
                                   body: update.required
                                       ? L("Update to keep playing with friends who have it. Tap Update at the top.")
                                       : L("New things to try. Tap Update at the top.")))
        }
        for notice in sources.notices {
            items.append(InboxItem(id: "notice:\(notice.id)", kind: .notice,
                                   title: notice.title(in: language), body: notice.body(in: language)))
        }
        return items
    }

    /// How many have not been seen.
    public static func unseenCount(_ items: [InboxItem], seen: Set<String>) -> Int {
        items.filter { !seen.contains($0.id) }.count
    }

    /// The seen ids once the list has been opened: everything showing, plus
    /// what was seen before, newest kept when there are too many.
    public static func markingSeen(_ items: [InboxItem], seen: [String]) -> [String] {
        var kept = seen.filter { id in !items.contains { $0.id == id } }
        kept.append(contentsOf: items.map(\.id))
        return Array(kept.suffix(keptSeen))
    }

    /// The ones to send as iPad notifications: new since the last look, and
    /// not sent before.
    public static func toPost(_ items: [InboxItem], seen: Set<String>, posted: Set<String>) -> [InboxItem] {
        items.filter { !seen.contains($0.id) && !posted.contains($0.id) }
    }
}
