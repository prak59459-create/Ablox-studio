import Foundation
import Network

/// A session found on the local network, as shown in the Play lobby.
public struct DiscoveredPeer: Identifiable, Hashable {
    public let id: String
    public let endpoint: NWEndpoint
    public let serviceName: String
    public let worldName: String
    public let hostName: String
    public let playerCount: Int
    public let capacity: Int
    public let isStudioSession: Bool
    public let protocolVersion: Int
    /// The room's code when the host made it public, so joining needs no
    /// typing. Nil for a private room: its code is only on the host's screen.
    public let publicCode: String?
    /// Mixed into the key made from the room code; see `TLSPeerSecurity`.
    public let keySalt: String

    public var isPublic: Bool { publicCode != nil }

    public var isFull: Bool { playerCount >= capacity }

    /// Whether this build can talk to that one.
    public var isCompatible: Bool { protocolVersion == AbloxProtocol.version }

    public var subtitle: String {
        if !isCompatible { return "Different Ablox version" }
        if isStudioSession { return "Studio · \(playerCount)/\(capacity) editing" }
        return "\(playerCount)/\(capacity) players"
    }

    public static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init?(result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }

        self.endpoint = result.endpoint
        self.serviceName = name
        self.id = name

        // Everything below comes from the TXT record, which lets the lobby
        // show a useful row before anyone connects. A host running an older
        // build may not publish every key, so each has a fallback.
        var txt: NWTXTRecord?
        if case let .bonjour(record) = result.metadata {
            txt = record
        }

        self.worldName = txt?[AbloxProtocol.TXTKey.worldName] ?? name
        self.hostName = txt?[AbloxProtocol.TXTKey.hostName] ?? name
        self.playerCount = Int(txt?[AbloxProtocol.TXTKey.players] ?? "") ?? 0
        self.capacity = Int(txt?[AbloxProtocol.TXTKey.capacity] ?? "") ?? AbloxProtocol.defaultCapacity
        self.isStudioSession = (txt?[AbloxProtocol.TXTKey.mode] ?? "play") == "studio"
        self.protocolVersion = Int(txt?[AbloxProtocol.TXTKey.protocolVersion] ?? "") ?? AbloxProtocol.version
        self.keySalt = txt?[AbloxProtocol.TXTKey.salt] ?? ""

        // Public only when the host says so *and* sends a code that could be
        // one. A host from before the setting sends neither: private.
        let code = RoomCode.normalize(txt?[AbloxProtocol.TXTKey.code] ?? "")
        if txt?[AbloxProtocol.TXTKey.access] == "public", RoomCode.isPlausible(code) {
            self.publicCode = code
        } else {
            self.publicCode = nil
        }
    }
}

/// Watches the local network for Ablox hosts.
///
/// Bonjour browsing is continuous rather than a one-shot scan: a host that
/// appears while the lobby is open shows up on its own, and one that goes away
/// disappears — no pull-to-refresh.
public final class AbloxBrowser {

    public enum State: Equatable {
        case stopped
        case browsing
        /// Local network permission was refused, or Wi-Fi is off.
        case unavailable(String)
    }

    public var onPeersChange: (([DiscoveredPeer]) -> Void)?
    public var onStateChange: ((State) -> Void)?

    public private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    public private(set) var peers: [DiscoveredPeer] = [] {
        didSet { onPeersChange?(peers) }
    }

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.ablox.browser", qos: .userInitiated)

    public init() {}

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        // Also find iPads reachable only over AWDL, with no shared Wi-Fi.
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: AbloxProtocol.bonjourServiceType, domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.state = .browsing
            case let .failed(error):
                self.state = .unavailable(PeerConnection.describe(error))
                // A failed browser never recovers; tear it down so a later
                // `start()` builds a fresh one.
                self.browser?.cancel()
                self.browser = nil
            case let .waiting(error):
                // The usual cause is the local-network permission prompt not
                // yet answered, or denied in Settings.
                self.state = .unavailable(Self.describeBrowseFailure(error))
            case .cancelled:
                self.state = .stopped
            case .setup:
                break
            @unknown default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let peers = results
                .compactMap(DiscoveredPeer.init(result:))
                .sorted { lhs, rhs in
                    // Joinable sessions first, then by world name so the list
                    // does not reshuffle as player counts change.
                    if lhs.isFull != rhs.isFull { return !lhs.isFull }
                    if lhs.isCompatible != rhs.isCompatible { return lhs.isCompatible }
                    return lhs.worldName.localizedCaseInsensitiveCompare(rhs.worldName) == .orderedAscending
                }
            self.peers = peers
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.browser?.cancel()
            self.browser = nil
            self.peers = []
            self.state = .stopped
        }
    }

    private static func describeBrowseFailure(_ error: NWError) -> String {
        // Matching on `.dns` as a whole rather than on
        // `kDNSServiceErr_PolicyDenied`: that constant lives in the `dnssd`
        // module, which `Network` does not re-export, and the policy denial is
        // overwhelmingly the DNS failure a Bonjour browser hits on iOS. The
        // generic phrasing is right either way.
        if case .dns = error {
            return "Ablox needs permission to find nearby iPads. Turn on Local Network for Ablox in Settings › Privacy & Security."
        }
        return PeerConnection.describe(error)
    }
}
