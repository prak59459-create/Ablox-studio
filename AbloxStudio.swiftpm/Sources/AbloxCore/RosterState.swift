import Foundation

/// Who is in the session and where they are, as one device sees it.
///
/// ## Why this exists
///
/// Two bugs, found on real iPads, both about position:
///
/// 1. **The host never saw anyone move.** It received every client's
///    transform, updated its internal state and relayed it to the other
///    clients — and never told its own screen. The host's roster was only
///    refreshed on join, leave and score changes, so a joined player stood
///    frozen at their spawn point on the host's iPad however far they walked.
///
/// 2. **A joining player ignored where the host put them.** The host assigns
///    each player their own spawn point. The client never read it and always
///    started at spawn zero — the host's spot — so the two disagreed about
///    where the joiner was from the first frame.
///
/// Both came from the same place: the host and the client each kept the roster
/// with their own ad hoc code, in the one layer that cannot be compiled or
/// tested off-device. This is that bookkeeping, pulled into the portable core
/// and used by both roles, so the same rules apply to both and a test can hold
/// them.
public struct RosterState: Equatable, Sendable {

    public let localPeerID: PeerID
    public private(set) var players: [PlayerSnapshot] = []

    /// Transforms for peers not yet in the roster.
    ///
    /// The roster and the transforms arrive by different paths, and on the
    /// main actor their order is not guaranteed — so the first movement of a
    /// player who has just joined can land before the roster that introduces
    /// them. Dropping it would leave them frozen until they next moved; this
    /// keeps the newest one and applies it when they appear.
    private var pending: [PeerID: PlayerTransformPayload] = [:]

    /// Whether the local player has been put where the host assigned them.
    /// Once only: a later roster (someone joined, someone scored) must not
    /// yank the player back to the start.
    private var hasPlacedLocalPlayer = false

    public init(localPeerID: PeerID) {
        self.localPeerID = localPeerID
    }

    /// Something the owner has to act on.
    public enum Event: Equatable, Sendable {
        /// Move the local player here. Sent once, the first time the host's
        /// roster includes them.
        case placeLocalPlayer(at: Vec3)
    }

    // MARK: Rosters

    /// Takes a full roster from the host.
    ///
    /// Positions for players already known are *kept*. A roster is sent on
    /// join, leave and score changes; transforms arrive twenty times a second.
    /// The roster's positions are therefore older than the ones already held,
    /// and taking them would make every avatar hitch backwards whenever
    /// anybody scored a point.
    @discardableResult
    public mutating func replace(with roster: [PlayerSnapshot]) -> [Event] {
        var events: [Event] = []
        let known = Dictionary(players.map { ($0.peerID, $0) }, uniquingKeysWith: { first, _ in first })

        players = roster.map { incoming in
            var merged = incoming

            if let existing = known[incoming.peerID], incoming.peerID != localPeerID {
                merged.position = existing.position
                merged.yawDegrees = existing.yawDegrees
                merged.velocity = existing.velocity
                merged.isGrounded = existing.isGrounded
            }

            if let newer = pending.removeValue(forKey: incoming.peerID), incoming.peerID != localPeerID {
                merged.apply(newer)
            }

            return merged
        }

        if !hasPlacedLocalPlayer, let me = players.first(where: { $0.peerID == localPeerID }) {
            hasPlacedLocalPlayer = true
            events.append(.placeLocalPlayer(at: me.position))
        }

        // Anyone pending who is still not in the roster has left, or never
        // arrived. Keeping them would leak a little per departure.
        let present = Set(players.map(\.peerID))
        pending = pending.filter { present.contains($0.key) }

        return events
    }

    // MARK: Transforms

    /// Applies another player's movement.
    ///
    /// The local player's own transform is ignored: it can come back as an
    /// echo, and the local simulation is the authority on where we are.
    public mutating func apply(_ transform: PlayerTransformPayload) {
        guard transform.peerID != localPeerID else { return }

        guard let index = players.firstIndex(where: { $0.peerID == transform.peerID }) else {
            // Not introduced yet — hold the newest one. See `pending`.
            pending[transform.peerID] = transform
            return
        }
        players[index].apply(transform)
    }

    // MARK: Reading

    public var localPlayer: PlayerSnapshot? {
        players.first { $0.peerID == localPeerID }
    }

    public var otherPlayers: [PlayerSnapshot] {
        players.filter { $0.peerID != localPeerID }
    }

    public func player(_ peer: PeerID) -> PlayerSnapshot? {
        players.first { $0.peerID == peer }
    }

    /// Everything forgotten, for leaving a session. The next session places
    /// the local player again.
    public mutating func reset() {
        players = []
        pending = [:]
        hasPlacedLocalPlayer = false
    }
}

public extension PlayerSnapshot {
    /// Takes the moving parts of a transform, leaving name, avatar and score.
    mutating func apply(_ transform: PlayerTransformPayload) {
        position = transform.position
        yawDegrees = transform.yawDegrees
        velocity = transform.velocity
        isGrounded = transform.isGrounded
    }
}
