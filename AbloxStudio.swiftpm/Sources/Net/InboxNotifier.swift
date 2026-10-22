import Foundation
import UserNotifications
import AbloxCore

/// The bell's new items as iPad notifications (8.8), when Settings →
/// Notifications is on: a friend's invitation shows even in the middle of a
/// game, and the app's icon carries the count.
///
/// Only local notifications, sent while Ablox is open: there is no server to
/// send them while it is closed. Inside Swift Playgrounds the iPad may ask
/// about Swift Playgrounds itself; an installed copy (the IPA) asks for Ablox.
@MainActor
public final class InboxNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    public static let shared = InboxNotifier()

    private static let enabledKey = "ablox.inbox.notify"
    private static let postedKey = "ablox.inbox.posted"
    private static let seenKey = "ablox.inbox.seen"

    /// Settings → Notifications. Off until turned on.
    @Published public private(set) var isEnabled: Bool
    /// The iPad said no: shown under the switch.
    @Published public private(set) var wasRefused = false
    /// Ids the bell's list has shown.
    @Published public private(set) var seen: [String]

    private let defaults: UserDefaults
    private var posted: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        seen = defaults.stringArray(forKey: Self.seenKey) ?? []
        posted = defaults.stringArray(forKey: Self.postedKey) ?? []
        super.init()
    }

    /// Turns iPad notifications on (asking the iPad first) or off.
    public func setEnabled(_ on: Bool) async {
        guard on else {
            isEnabled = false
            wasRefused = false
            defaults.set(false, forKey: Self.enabledKey)
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        isEnabled = granted
        wasRefused = !granted
        defaults.set(granted, forKey: Self.enabledKey)
    }

    /// The list was opened: everything in it is seen.
    public func markSeen(_ items: [InboxItem]) {
        seen = AbloxInbox.markingSeen(items, seen: seen)
        defaults.set(seen, forKey: Self.seenKey)
        Task { await updateBadge(items) }
    }

    /// What changed in the bell: new items become notifications, once each.
    public func itemsChanged(_ items: [InboxItem]) {
        guard isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let fresh = AbloxInbox.toPost(items, seen: Set(seen), posted: Set(posted))
        for item in fresh {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
        if !fresh.isEmpty {
            posted = Array((posted + fresh.map(\.id)).suffix(AbloxInbox.keptSeen))
            defaults.set(posted, forKey: Self.postedKey)
        }
        Task { await updateBadge(items) }
    }

    private func updateBadge(_ items: [InboxItem]) async {
        guard isEnabled else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(AbloxInbox.unseenCount(items, seen: Set(seen)))
    }

    /// Shown while Ablox is open, too: that is the only time they are sent.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
