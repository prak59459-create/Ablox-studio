import Foundation

// Changes to the world, collected as they arrive and taken in one go.
//
// A busy game changes its world many times a second: a character is
// eighteen blocks, a sign's words change, a meme walks. Applying each change
// on the main thread as its own task, copying the world each time and then
// re-checking every block on screen, cost more than drawing the frame. Now
// changes wait here, the session applies them all at once, and the renderer
// is told exactly which blocks to look at.

/// Which blocks changed since the renderer last looked.
public struct WorldChangeLog: Sendable, Equatable {
    /// Blocks inserted or updated.
    public private(set) var blocks: Set<UUID> = []
    /// Blocks removed, each with everything hung from it.
    public private(set) var removed: Set<UUID> = []
    /// Something only a full comparison catches: blocks moved to another
    /// parent, the pictures, or a whole new world.
    public private(set) var everything: Bool

    /// More changed blocks than this and a full comparison is quicker.
    public static let limit = 512

    public init(everything: Bool = true) {
        self.everything = everything
    }

    public var isEmpty: Bool { !everything && blocks.isEmpty && removed.isEmpty }

    public mutating func note(_ delta: WorldDelta) {
        switch delta {
        case let .insert(block), let .update(block):
            note(block: block.id)
        case let .remove(id):
            note(removed: id)
        case .reparent, .imagesReplaced:
            noteEverything()
        case .environment, .rulesReplaced, .scriptsReplaced, .scriptSourceChanged:
            // The renderer reads the environment every time it looks, and
            // rules and scripts are not drawn.
            break
        }
    }

    public mutating func note(block id: UUID) {
        guard !everything else { return }
        blocks.insert(id)
        if blocks.count + removed.count > Self.limit { noteEverything() }
    }

    public mutating func note(removed id: UUID) {
        guard !everything else { return }
        removed.insert(id)
        if blocks.count + removed.count > Self.limit { noteEverything() }
    }

    public mutating func noteEverything() {
        everything = true
        blocks.removeAll()
        removed.removeAll()
    }

    /// What has changed, leaving the log empty.
    public mutating func take() -> WorldChangeLog {
        let taken = self
        self = WorldChangeLog(everything: false)
        return taken
    }
}

/// World changes handed over from the network's queue to the main thread.
/// `add` says whether the caller should schedule a drain: only the first
/// change after a drain does, so a burst of them is one hop, not hundreds.
public final class WorldDeltaInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [WorldDelta] = []
    private var drainScheduled = false

    public init() {}

    /// Adds a change. True when nothing is waiting to drain them yet.
    public func add(_ delta: WorldDelta) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending.append(delta)
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    /// Everything waiting, oldest first.
    public func take() -> [WorldDelta] {
        lock.lock()
        defer { lock.unlock() }
        drainScheduled = false
        let taken = pending
        pending.removeAll(keepingCapacity: true)
        return taken
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty
    }
}

/// Where everyone else is, handed over from the network's queue: only each
/// player's newest position matters, so older ones are dropped on arrival.
public final class TransformInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [PeerID: PlayerTransformPayload] = [:]
    private var order: [PeerID] = []
    private var drainScheduled = false

    public init() {}

    /// Adds a position. True when nothing is waiting to drain them yet.
    public func add(_ payload: PlayerTransformPayload) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if latest.updateValue(payload, forKey: payload.peerID) == nil { order.append(payload.peerID) }
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    /// Each player's newest position, in the order they first arrived.
    public func take() -> [PlayerTransformPayload] {
        lock.lock()
        defer { lock.unlock() }
        drainScheduled = false
        let taken = order.compactMap { latest[$0] }
        latest.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        return taken
    }
}

/// Telling SwiftUI about changes it shows but that happen many times a
/// second (positions on the map, the world's blocks): at most this often.
public struct PublishThrottle: Sendable {
    public let interval: Double
    private var lastPublished: Double = -.infinity
    private var waiting = false

    public init(interval: Double = 0.1) {
        self.interval = interval
    }

    /// Called when something changed at time `now`. Returns `.now` to
    /// publish straight away, `.after(seconds)` to schedule one publish (the
    /// first change since the last one), or `.alreadyScheduled`.
    public enum Decision: Equatable, Sendable {
        case now
        case after(Double)
        case alreadyScheduled
    }

    public mutating func changed(at now: Double) -> Decision {
        if waiting { return .alreadyScheduled }
        let since = now - lastPublished
        if since >= interval {
            lastPublished = now
            return .now
        }
        waiting = true
        return .after(interval - since)
    }

    /// The scheduled publish happened.
    public mutating func published(at now: Double) {
        waiting = false
        lastPublished = now
    }
}
