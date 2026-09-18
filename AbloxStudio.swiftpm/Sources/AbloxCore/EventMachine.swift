import Foundation

/// The authoritative rule evaluator.
///
/// Runs **only on the host**. Clients report raw observations
/// (`EventTriggerPayload`) and receive resolved effects
/// (`EventEffectPayload`); they never decide for themselves that they scored a
/// point. That keeps scores consistent across the mesh and means one client's
/// physics hiccup cannot award it ten coins.
///
/// Deliberately free of Apple frameworks and of any clock of its own: time is
/// passed in. That makes every branch below directly unit-testable.
public struct EventMachine: Sendable {

    // MARK: Observations

    /// Something a client reported, or that the host itself noticed.
    public enum Observation: Hashable, Sendable {
        case roundStarted
        case touched(peer: PeerID, blockID: UUID)
        case tapped(peer: PeerID, blockID: UUID)
        /// Emitted by `advance(to:)` for proximity rules; also accepted
        /// directly so a client can report an early entry.
        case proximityEntered(peer: PeerID, blockID: UUID)
        case scoreChanged(peer: PeerID, newScore: Int)
    }

    /// A resolved effect, ready to be broadcast.
    public struct Effect: Hashable, Sendable {
        public var ruleID: UUID?
        /// Non-nil when the effect only concerns one player.
        public var targetPeerID: PeerID?
        public var action: EventAction

        public init(ruleID: UUID?, targetPeerID: PeerID?, action: EventAction) {
            self.ruleID = ruleID
            self.targetPeerID = targetPeerID
            self.action = action
        }
    }

    // MARK: State

    public private(set) var world: WorldDocument
    public private(set) var players: [PeerID: PlayerSnapshot] = [:]

    /// Per-rule bookkeeping for `cooldown` and `maxFireCount`.
    private var fireCounts: [UUID: Int] = [:]
    private var lastFiredAt: [UUID: Double] = [:]
    private var lastTimerFireAt: [UUID: Double] = [:]

    /// Collectibles already taken, per player, so a coin cannot be farmed.
    private var consumedBlocks: [PeerID: Set<UUID>] = [:]

    /// Which proximity pairs are currently "inside", so entering fires once.
    private var proximityInside: Set<ProximityKey> = []

    /// Where each player respawns — updated by checkpoints.
    private var respawnPoints: [PeerID: Vec3] = [:]

    /// Last firing time per gimmick block, for `GimmickSettings.cooldown`.
    private var blockCooldowns: [UUID: Double] = [:]

    /// Deferred gimmick effects, ordered by due time. A disappearing platform
    /// is two of these: vanish, then return.
    private var scheduled: [(due: Double, action: ScheduledAction)] = []

    /// Work `advance(to:)` performs once its due time arrives.
    private enum ScheduledAction: Hashable, Sendable {
        case hideBlock(UUID)
        case showBlock(UUID)
    }

    private var now: Double = 0
    private var hasStarted = false
    public private(set) var isRoundOver = false

    private struct ProximityKey: Hashable, Sendable {
        let peer: PeerID
        let block: UUID
    }

    public init(world: WorldDocument, startTime: Double = 0) {
        self.world = world
        self.now = startTime
    }

    // MARK: Roster

    public mutating func addPlayer(_ snapshot: PlayerSnapshot) {
        var snapshot = snapshot
        if respawnPoints[snapshot.peerID] == nil {
            let spawn = world.spawnPosition(forPlayerIndex: players.count)
            respawnPoints[snapshot.peerID] = spawn
            // A player joining mid-round starts at the spawn, not at whatever
            // stale position their handshake carried.
            snapshot.position = spawn
        }
        players[snapshot.peerID] = snapshot
    }

    public mutating func removePlayer(_ peer: PeerID) {
        players.removeValue(forKey: peer)
        consumedBlocks.removeValue(forKey: peer)
        respawnPoints.removeValue(forKey: peer)
        proximityInside = proximityInside.filter { $0.peer != peer }
    }

    public mutating func updateTransform(_ payload: PlayerTransformPayload) {
        guard var player = players[payload.peerID] else { return }
        player.position = payload.position
        player.yawDegrees = payload.yawDegrees
        player.velocity = payload.velocity
        player.isGrounded = payload.isGrounded
        players[payload.peerID] = player
    }

    public func player(_ peer: PeerID) -> PlayerSnapshot? { players[peer] }

    public var roster: [PlayerSnapshot] {
        players.values.sorted { $0.profile.displayName < $1.profile.displayName }
    }

    public func respawnPoint(for peer: PeerID) -> Vec3 {
        respawnPoints[peer] ?? world.spawnPosition(forPlayerIndex: 0)
    }

    /// Blocks this player has already collected, so a late-joining client can
    /// hide them immediately.
    public func consumedBlocks(for peer: PeerID) -> Set<UUID> {
        consumedBlocks[peer] ?? []
    }

    // MARK: World edits

    /// Applies a live edit from Studio. Rules keyed to a removed block are
    /// dropped by `WorldDocument.remove(id:)`, so the machine's bookkeeping is
    /// pruned to match.
    public mutating func apply(_ delta: WorldDelta) {
        delta.apply(to: &world)
        let liveRuleIDs = Set(world.rules.map(\.id))
        fireCounts = fireCounts.filter { liveRuleIDs.contains($0.key) }
        lastFiredAt = lastFiredAt.filter { liveRuleIDs.contains($0.key) }
        lastTimerFireAt = lastTimerFireAt.filter { liveRuleIDs.contains($0.key) }
    }

    // MARK: Time

    /// Advances the clock, firing timer rules and re-testing proximity.
    /// `time` is a monotonic seconds value supplied by the caller.
    public mutating func advance(to time: Double) -> [Effect] {
        guard time >= now else { return [] }
        now = time
        guard hasStarted, !isRoundOver else { return [] }

        var effects: [Effect] = []
        effects.append(contentsOf: fireScheduled())
        effects.append(contentsOf: fireTimerRules())
        effects.append(contentsOf: evaluateProximity())
        effects.append(contentsOf: enforceKillPlane())
        return effects
    }

    // MARK: Main entry point

    /// Feeds one observation through the rules and the built-in block
    /// behaviours, returning everything that should be broadcast.
    public mutating func handle(_ observation: Observation) -> [Effect] {
        guard !isRoundOver || observation == .roundStarted else { return [] }

        var effects: [Effect] = []

        switch observation {
        case .roundStarted:
            hasStarted = true
            isRoundOver = false
            fireCounts.removeAll()
            lastFiredAt.removeAll()
            lastTimerFireAt.removeAll()
            consumedBlocks.removeAll()
            proximityInside.removeAll()
            blockCooldowns.removeAll()
            scheduled.removeAll()
            // Anchor every timer to the start of the round. Seeding them
            // lazily on the first `advance(to:)` instead would make the first
            // interval depend on when the render loop happened to tick.
            for rule in world.rules {
                if case .timer = rule.trigger { lastTimerFireAt[rule.id] = now }
            }
            effects.append(contentsOf: fireRules(matching: { if case .worldStart = $0 { return true }; return false }, peer: nil))

        case let .touched(peer, blockID):
            effects.append(contentsOf: applyBuiltInBehavior(peer: peer, blockID: blockID))
            // Snapshot the tags before calling the mutating `fireRules`: the
            // predicate closure must not touch `self` while it is exclusive.
            let touchedTags = world.block(id: blockID)?.tags ?? []
            effects.append(contentsOf: fireRules(matching: { trigger in
                switch trigger {
                case let .blockTouched(id):
                    return id == blockID
                case let .tagTouched(tag):
                    return touchedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                default:
                    return false
                }
            }, peer: peer))

        case let .tapped(peer, blockID):
            effects.append(contentsOf: fireRules(matching: { trigger in
                if case let .blockTapped(id) = trigger { return id == blockID }
                return false
            }, peer: peer))

        case let .proximityEntered(peer, blockID):
            let key = ProximityKey(peer: peer, block: blockID)
            guard !proximityInside.contains(key) else { break }
            proximityInside.insert(key)
            effects.append(contentsOf: fireRules(matching: { trigger in
                if case let .proximity(id, _) = trigger { return id == blockID }
                return false
            }, peer: peer))

        case let .scoreChanged(peer, newScore):
            players[peer]?.score = newScore
            effects.append(contentsOf: fireRules(matching: { trigger in
                if case let .scoreReached(target) = trigger { return newScore >= target }
                return false
            }, peer: peer))
        }

        // Applying effects can itself change scores, which can trip a
        // `scoreReached` rule. Resolve that one level deep — enough for the
        // "collect 10 coins to win" case without risking a rule loop.
        let scoreEffects = effects.filter { if case .awardPoints = $0.action { return true }; return false }
        if !scoreEffects.isEmpty {
            for effect in scoreEffects {
                guard let peer = effect.targetPeerID, let score = players[peer]?.score else { continue }
                effects.append(contentsOf: fireRules(matching: { trigger in
                    if case let .scoreReached(target) = trigger { return score >= target }
                    return false
                }, peer: peer))
            }
        }

        if effects.contains(where: { if case .endRound = $0.action { return true }; return false }) {
            isRoundOver = true
        }

        return effects
    }

    // MARK: Built-in behaviours

    /// The behaviours every world gets for free, before any authored rule.
    private mutating func applyBuiltInBehavior(peer: PeerID, blockID: UUID) -> [Effect] {
        guard let block = world.block(id: blockID) else { return [] }

        switch block.behavior {
        case .none, .spawn, .trigger:
            return []

        case .checkpoint:
            let top = topSurfacePosition(of: block)
            // Re-touching the checkpoint you already hold is not an event.
            guard respawnPoints[peer] != top else { return [] }
            respawnPoints[peer] = top
            return [
                Effect(ruleID: nil, targetPeerID: peer, action: .announce(message: "Checkpoint reached", duration: 1.5)),
                Effect(ruleID: nil, targetPeerID: peer, action: .playSound(name: "checkpoint"))
            ]

        case .hazard:
            var effects: [Effect] = [
                Effect(ruleID: nil, targetPeerID: peer, action: .teleportPlayer(to: respawnPoint(for: peer))),
                Effect(ruleID: nil, targetPeerID: peer, action: .playSound(name: "hurt"))
            ]
            if block.scoreValue != 0 {
                effects.append(contentsOf: award(points: -abs(block.scoreValue), to: peer, ruleID: nil))
            }
            return effects

        case .collectible:
            var taken = consumedBlocks[peer] ?? []
            // Already collected: silently ignore, the client just has a stale
            // view of the block.
            guard taken.insert(blockID).inserted else { return [] }
            consumedBlocks[peer] = taken
            var effects: [Effect] = [
                Effect(ruleID: nil, targetPeerID: peer, action: .setVisible(blockID: blockID, visible: false)),
                Effect(ruleID: nil, targetPeerID: peer, action: .playSound(name: "collect"))
            ]
            if block.scoreValue != 0 {
                effects.append(contentsOf: award(points: block.scoreValue, to: peer, ruleID: nil))
            }
            return effects

        case .goal:
            isRoundOver = true
            let name = players[peer]?.profile.displayName ?? "Someone"
            return [Effect(ruleID: nil, targetPeerID: nil, action: .endRound(message: "\(name) reached the goal!"))]

        // MARK: Gimmicks
        //
        // All three share a per-block cooldown. Contact is reported on every
        // collision step while a player stands on a block, so without it a
        // bounce pad would fire dozens of times a second.

        case .bounce:
            guard beginGimmick(on: block) else { return [] }
            return [
                Effect(ruleID: nil, targetPeerID: peer, action: .bouncePlayer(speed: block.gimmick.bounceSpeed)),
                Effect(ruleID: nil, targetPeerID: nil, action: .playSound(name: "bounce"))
            ]

        case .disappear:
            guard beginGimmick(on: block) else { return [] }
            // Nothing happens now: the grace period is the trap. Both the
            // vanish and the return are scheduled, and `advance(to:)` emits
            // them — which is why the machine needs a clock it is given
            // rather than one it reads.
            schedule(.hideBlock(block.id), at: now + block.gimmick.disappearDelay)
            schedule(
                .showBlock(block.id),
                at: now + block.gimmick.disappearDelay + Swift.max(0.1, block.gimmick.respawnDelay)
            )
            return [Effect(ruleID: nil, targetPeerID: nil, action: .tint(
                blockID: block.id,
                color: block.color.withAlpha(0.35),
                duration: block.gimmick.disappearDelay
            ))]

        case .teleport:
            // A pad with no target, or one pointing at a deleted block, is
            // inert. Dropping the player at the origin would be worse.
            guard let targetID = block.gimmick.teleportTargetID,
                  let target = world.block(id: targetID),
                  targetID != block.id,
                  beginGimmick(on: block) else { return [] }
            return [
                Effect(ruleID: nil, targetPeerID: peer, action: .teleportPlayer(to: topSurfacePosition(of: target))),
                Effect(ruleID: nil, targetPeerID: nil, action: .playSound(name: "teleport"))
            ]
        }
    }

    /// Consumes a gimmick block's cooldown, returning false while it is still
    /// cooling down.
    private mutating func beginGimmick(on block: BlockData) -> Bool {
        if let last = blockCooldowns[block.id], now - last < block.gimmick.cooldown {
            return false
        }
        blockCooldowns[block.id] = now
        return true
    }

    private mutating func award(points: Int, to peer: PeerID, ruleID: UUID?) -> [Effect] {
        guard var player = players[peer] else { return [] }
        player.score += points
        players[peer] = player
        return [Effect(ruleID: ruleID, targetPeerID: peer, action: .awardPoints(points))]
    }

    /// World-space position just above a block's top face.
    private func topSurfacePosition(of block: BlockData) -> Vec3 {
        let t = world.worldTransform(of: block.id)
        let halfHeight = block.shape.unitBounds.size.y * t.scale.y * 0.5
        return Vec3(t.position.x, t.position.y + halfHeight + 1.0, t.position.z)
    }

    // MARK: Rule firing

    private mutating func fireRules(matching predicate: (EventTrigger) -> Bool, peer: PeerID?) -> [Effect] {
        var effects: [Effect] = []
        for rule in world.rules where rule.isEnabled && predicate(rule.trigger) {
            guard canFire(rule) else { continue }
            noteFired(rule)
            effects.append(contentsOf: resolve(rule: rule, peer: peer))
        }
        return effects
    }

    private mutating func fireTimerRules() -> [Effect] {
        var effects: [Effect] = []
        for rule in world.rules where rule.isEnabled {
            guard case let .timer(interval) = rule.trigger, interval > 0 else { continue }
            guard let last = lastTimerFireAt[rule.id] else {
                // A timer authored mid-round starts counting from now, rather
                // than firing immediately because it has never fired.
                lastTimerFireAt[rule.id] = now
                continue
            }
            guard now - last >= interval else { continue }
            guard canFire(rule) else {
                lastTimerFireAt[rule.id] = now
                continue
            }
            lastTimerFireAt[rule.id] = now
            noteFired(rule)
            effects.append(contentsOf: resolve(rule: rule, peer: nil))
        }
        return effects
    }

    private mutating func evaluateProximity() -> [Effect] {
        var effects: [Effect] = []
        for rule in world.rules where rule.isEnabled {
            guard case let .proximity(blockID, radius) = rule.trigger else { continue }
            guard world.block(id: blockID) != nil else { continue }
            let target = world.worldPosition(of: blockID)

            for (peerID, player) in players {
                let key = ProximityKey(peer: peerID, block: blockID)
                let inside = player.position.horizontalDistance(to: target) <= radius
                if inside, !proximityInside.contains(key) {
                    proximityInside.insert(key)
                    guard canFire(rule) else { continue }
                    noteFired(rule)
                    effects.append(contentsOf: resolve(rule: rule, peer: peerID))
                } else if !inside {
                    // Hysteresis: only leave once clearly outside, so a player
                    // standing on the boundary does not machine-gun the rule.
                    if player.position.horizontalDistance(to: target) > radius * 1.15 {
                        proximityInside.remove(key)
                    }
                }
            }
        }
        return effects
    }

    private mutating func enforceKillPlane() -> [Effect] {
        var effects: [Effect] = []
        let floor = world.environment.killPlaneHeight
        for (peerID, player) in players where player.position.y < floor {
            let spawn = respawnPoint(for: peerID)
            players[peerID]?.position = spawn
            players[peerID]?.velocity = .zero
            effects.append(Effect(ruleID: nil, targetPeerID: peerID, action: .teleportPlayer(to: spawn)))
        }
        return effects
    }

    private mutating func schedule(_ action: ScheduledAction, at due: Double) {
        // A block already queued for the same action is left alone, so a
        // player bouncing on a platform mid-cycle cannot stack restores.
        guard !scheduled.contains(where: { $0.action == action }) else { return }
        scheduled.append((due: due, action: action))
    }

    /// Emits any scheduled gimmick effects that have come due.
    ///
    /// The world document is updated alongside the broadcast so a player who
    /// joins while a platform is missing sees it missing.
    private mutating func fireScheduled() -> [Effect] {
        guard !scheduled.isEmpty else { return [] }

        let due = scheduled.filter { $0.due <= now }
        guard !due.isEmpty else { return [] }
        scheduled.removeAll { $0.due <= now }

        var effects: [Effect] = []
        for item in due {
            switch item.action {
            case let .hideBlock(id):
                guard world.block(id: id) != nil else { continue }
                world.mutate(id: id) { $0.isVisible = false; $0.hasCollision = false }
                effects.append(Effect(ruleID: nil, targetPeerID: nil, action: .setVisible(blockID: id, visible: false)))
                effects.append(Effect(ruleID: nil, targetPeerID: nil, action: .setCollision(blockID: id, enabled: false)))

            case let .showBlock(id):
                guard world.block(id: id) != nil else { continue }
                world.mutate(id: id) { $0.isVisible = true; $0.hasCollision = true }
                effects.append(Effect(ruleID: nil, targetPeerID: nil, action: .setVisible(blockID: id, visible: true)))
                effects.append(Effect(ruleID: nil, targetPeerID: nil, action: .setCollision(blockID: id, enabled: true)))
            }
        }
        return effects
    }

    private func canFire(_ rule: EventRule) -> Bool {
        if let limit = rule.maxFireCount, (fireCounts[rule.id] ?? 0) >= limit { return false }
        if let last = lastFiredAt[rule.id], now - last < rule.cooldown { return false }
        return true
    }

    private mutating func noteFired(_ rule: EventRule) {
        fireCounts[rule.id, default: 0] += 1
        lastFiredAt[rule.id] = now
    }

    private mutating func resolve(rule: EventRule, peer: PeerID?) -> [Effect] {
        var effects: [Effect] = []
        for action in rule.actions {
            switch action {
            case let .awardPoints(points):
                guard let peer else { continue }
                effects.append(contentsOf: award(points: points, to: peer, ruleID: rule.id))

            case .teleportPlayer:
                // Personal: only the triggering player moves.
                guard let peer else { continue }
                effects.append(Effect(ruleID: rule.id, targetPeerID: peer, action: action))

            case .endRound:
                isRoundOver = true
                effects.append(Effect(ruleID: rule.id, targetPeerID: nil, action: action))

            case let .setVisible(blockID, visible):
                // World-level changes are mirrored into the document so a
                // player joining later sees the current state.
                world.mutate(id: blockID) { $0.isVisible = visible }
                effects.append(Effect(ruleID: rule.id, targetPeerID: nil, action: action))

            case let .setCollision(blockID, enabled):
                world.mutate(id: blockID) { $0.hasCollision = enabled }
                effects.append(Effect(ruleID: rule.id, targetPeerID: nil, action: action))

            case let .tint(blockID, color, duration):
                // Instant tints update the document; animated ones are left to
                // the client so the host is not simulating colour ramps.
                if duration <= 0 {
                    world.mutate(id: blockID) { $0.color = color }
                }
                effects.append(Effect(ruleID: rule.id, targetPeerID: nil, action: action))

            case let .move(blockID, offset, duration):
                if duration <= 0 {
                    world.mutate(id: blockID) { $0.position += offset }
                }
                effects.append(Effect(ruleID: rule.id, targetPeerID: nil, action: action))

            case .announce, .playSound:
                effects.append(Effect(ruleID: rule.id, targetPeerID: nil, action: action))

            case .bouncePlayer:
                // Personal, like a teleport: only whoever set it off is moved.
                guard let peer else { continue }
                effects.append(Effect(ruleID: rule.id, targetPeerID: peer, action: action))
            }
        }
        return effects
    }
}

// MARK: - Effect grouping

public extension Array where Element == EventMachine.Effect {
    /// Splits effects into the broadcast payloads the host should send:
    /// one shared payload plus one per targeted player.
    func groupedIntoPayloads() -> (broadcast: EventEffectPayload?, targeted: [PeerID: EventEffectPayload]) {
        let shared = filter { $0.targetPeerID == nil }
        var perPeer: [PeerID: [EventMachine.Effect]] = [:]
        for effect in self {
            guard let peer = effect.targetPeerID else { continue }
            perPeer[peer, default: []].append(effect)
        }

        let broadcast = shared.isEmpty
            ? nil
            : EventEffectPayload(ruleID: shared.first?.ruleID, targetPeerID: nil, actions: shared.map(\.action))

        let targeted = perPeer.mapValues { effects in
            EventEffectPayload(ruleID: effects.first?.ruleID, targetPeerID: effects.first?.targetPeerID, actions: effects.map(\.action))
        }

        return (broadcast, targeted)
    }
}
