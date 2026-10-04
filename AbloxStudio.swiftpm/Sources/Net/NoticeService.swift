import Foundation
import Combine

/// Notices for the main menu, published as `notices.json` beside
/// `update.json` in the app's repository: an event, something fixed, a
/// server that is down.
///
/// The last copy is kept on disk and shown straight away; a fresh one is
/// fetched at most every few hours. A notice closed with × stays closed.
@MainActor
public final class NoticeService: ObservableObject {

    @Published public private(set) var notices: [AppNotice] = []
    @Published public private(set) var dismissed: Set<String>

    private let url: URL?
    private let app: String
    private let version: AppVersion?
    private let cacheURL: URL
    private static let dismissedKey = "ablox.notices.dismissed"
    private static let checkedKey = "ablox.notices.checked"

    public init(release: InstalledApp) {
        url = release.channel.noticesURL
        app = release.app
        version = release.version
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = base.appendingPathComponent("notices.json")
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        if let data = try? Data(contentsOf: cacheURL), let cached = NoticeBoard.decode(data) {
            notices = cached
        }
    }

    /// What to show today.
    public var active: [AppNotice] {
        NoticeBoard.active(notices, app: app, version: version, today: NoticeBoard.day(Date()), dismissed: dismissed)
    }

    public func dismiss(_ notice: AppNotice) {
        dismissed.insert(notice.id)
        // Only ids still published, so the list does not grow forever.
        let published = Set(notices.map(\.id))
        UserDefaults.standard.set(Array(dismissed.filter { published.contains($0) }), forKey: Self.dismissedKey)
    }

    public func refreshIfDue() async {
        let last = UserDefaults.standard.double(forKey: Self.checkedKey)
        guard Date().timeIntervalSince1970 - last > NoticeBoard.checkInterval || notices.isEmpty else { return }
        await refresh()
    }

    public func refresh() async {
        guard let url else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
        guard let fresh = NoticeBoard.decode(data) else { return }
        notices = fresh
        try? data.write(to: cacheURL, options: .atomic)
    }
}
