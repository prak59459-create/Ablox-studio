import Foundation

/// The player's collision volume: an axis-aligned box standing on its origin.
///
/// A box rather than a capsule because every block in Ablox is a box-ish
/// primitive, and box-vs-box resolution is exact, cheap and — most usefully —
/// deterministic, so host and client agree without any reconciliation.
public struct CharacterBody: Hashable, Sendable {
    /// Half the width and depth.
    public var radius: Float
    public var height: Float
    /// How far the player can rise over an obstacle without jumping. Lets a
    /// staircase of shallow steps be walked up instead of jumped up.
    public var stepHeight: Float

    public init(radius: Float = 0.4, height: Float = 1.8, stepHeight: Float = 0.45) {
        self.radius = radius
        self.height = height
        self.stepHeight = stepHeight
    }

    public static let `default` = CharacterBody()

    /// The body's bounds with its feet at `position`.
    public func bounds(at position: Vec3) -> BoundingBox {
        BoundingBox(
            center: Vec3(position.x, position.y + height * 0.5, position.z),
            size: Vec3(radius * 2, height, radius * 2)
        )
    }
}

public struct CollisionResult: Hashable, Sendable {
    public var position: Vec3
    public var velocity: Vec3
    public var isGrounded: Bool
    /// Blocks whose volume the player overlapped this step — coins, hazards,
    /// checkpoints. Reported, never blocking.
    public var touchedBlockIDs: [UUID]

    public init(position: Vec3, velocity: Vec3, isGrounded: Bool, touchedBlockIDs: [UUID]) {
        self.position = position
        self.velocity = velocity
        self.isGrounded = isGrounded
        self.touchedBlockIDs = touchedBlockIDs
    }
}

/// Kinematic character collision against a `WorldDocument`.
///
/// Deliberately not RealityKit physics. A dynamic rigid body for the player
/// would be simulated independently on every iPad, and two devices stepping
/// the same contact would drift apart within seconds. Solving movement here —
/// in plain, deterministic Swift against the shared document — means the host
/// and every client compute the same answer from the same inputs, and it can
/// be unit-tested without a device.
public enum WorldCollider {

    /// One collision step.
    ///
    /// Axes are resolved separately, horizontal before vertical. That order is
    /// what makes walking off a ledge and landing on a platform behave: the
    /// horizontal move happens first and can be stopped by a wall, then the
    /// vertical move settles the player onto whatever is underneath.
    public static func resolve(
        position: Vec3,
        velocity: Vec3,
        body: CharacterBody = .default,
        world: WorldDocument,
        deltaTime: Float
    ) -> CollisionResult {
        let dt = Swift.max(0, Swift.min(deltaTime, 0.1))

        var solids: [BoundingBox] = []
        var triggers: [(id: UUID, box: BoundingBox)] = []

        for block in world.blocks {
            guard block.isVisible, block.hasCollision else {
                // An invisible or non-colliding block can still be a trigger
                // the author expects to fire, but only if it means something.
                if block.behavior.needsTouchDetection, block.isVisible,
                   let box = world.worldBounds(of: block.id) {
                    triggers.append((block.id, box))
                }
                continue
            }
            guard let box = world.worldBounds(of: block.id) else { continue }

            if isPassThrough(block.behavior) {
                triggers.append((block.id, box))
            } else {
                solids.append(box)
                if block.behavior.needsTouchDetection {
                    triggers.append((block.id, box))
                }
            }
        }

        var p = position
        var v = velocity
        var grounded = false

        // --- Horizontal: X ---
        p.x += v.x * dt
        if let correction = resolveAxis(.x, position: &p, velocity: v.x, body: body, solids: solids, stepHeight: body.stepHeight) {
            v.x = correction
        }

        // --- Horizontal: Z ---
        p.z += v.z * dt
        if let correction = resolveAxis(.z, position: &p, velocity: v.z, body: body, solids: solids, stepHeight: body.stepHeight) {
            v.z = correction
        }

        // --- Vertical ---
        // Capture the direction before resolving: the first contact zeroes
        // `v.y`, and a later iteration must not read that as "moving down"
        // and push the player up through the ceiling it just hit.
        let movingUp = v.y > 0
        p.y += v.y * dt
        if resolveVertical(position: &p, velocity: &v, body: body, solids: solids, movingUp: movingUp), !movingUp {
            grounded = true
        }

        // Standing exactly on a surface with zero vertical velocity still
        // counts as grounded, otherwise a stationary player reads as airborne
        // and cannot jump. Probing downward by more than the penetration
        // epsilon is what turns "touching" into "resting on".
        if !grounded, v.y <= 0 {
            var probe = p
            probe.y -= groundProbeDepth
            let probeBox = body.bounds(at: probe)
            grounded = solids.contains { probeBox.penetrates($0) }
        }

        let playerBox = body.bounds(at: p)
        let touched = triggers.filter { $0.box.intersects(playerBox) }.map(\.id)

        return CollisionResult(position: p, velocity: v, isGrounded: grounded, touchedBlockIDs: touched)
    }

    /// Behaviours a player walks through rather than into.
    private static func isPassThrough(_ behavior: BlockBehavior) -> Bool {
        switch behavior {
        case .collectible, .checkpoint, .spawn, .trigger:
            return true
        case .none, .hazard, .goal:
            return false
        }
    }

    /// How far below the feet to look when deciding "am I standing on
    /// something". Must exceed the penetration epsilon, or a player resting
    /// exactly on a surface never registers as grounded.
    private static let groundProbeDepth: Float = 0.05

    private enum Axis { case x, z }

    /// Pushes the body out of anything it now overlaps on one horizontal axis.
    /// Returns the corrected velocity component, or nil when nothing was hit.
    private static func resolveAxis(
        _ axis: Axis,
        position p: inout Vec3,
        velocity: Float,
        body: CharacterBody,
        solids: [BoundingBox],
        stepHeight: Float
    ) -> Float? {
        guard velocity != 0 else { return nil }

        var hitSomething = false
        // Several overlaps can need resolving in sequence (an inside corner),
        // but a bounded loop keeps one bad frame from spinning forever.
        for _ in 0..<4 {
            let box = body.bounds(at: p)
            guard let blocker = solids.first(where: { box.penetrates($0) }) else { break }

            // A low obstacle is stepped over rather than walked into.
            let rise = blocker.max.y - p.y
            if rise > 0, rise <= stepHeight {
                var stepped = p
                stepped.y = blocker.max.y
                let steppedBox = body.bounds(at: stepped)
                if !solids.contains(where: { steppedBox.penetrates($0) }) {
                    p = stepped
                    continue
                }
            }

            hitSomething = true
            switch axis {
            case .x:
                p.x += velocity > 0 ? (blocker.min.x - box.max.x) : (blocker.max.x - box.min.x)
            case .z:
                p.z += velocity > 0 ? (blocker.min.z - box.max.z) : (blocker.max.z - box.min.z)
            }
        }

        return hitSomething ? 0 : nil
    }

    /// Returns true when the body came to rest on top of something.
    ///
    /// `movingUp` is passed in rather than re-read from `v.y`, because the
    /// first contact sets `v.y` to zero and a second iteration would otherwise
    /// resolve a ceiling as if it were a floor.
    private static func resolveVertical(
        position p: inout Vec3,
        velocity v: inout Vec3,
        body: CharacterBody,
        solids: [BoundingBox],
        movingUp: Bool
    ) -> Bool {
        var landed = false
        for _ in 0..<4 {
            let box = body.bounds(at: p)
            guard let blocker = solids.first(where: { box.penetrates($0) }) else { break }

            if movingUp {
                // Hit a ceiling: stop rising, and start falling immediately
                // rather than sticking to it.
                p.y += blocker.min.y - box.max.y
            } else {
                p.y += blocker.max.y - box.min.y
                landed = true
            }
            v.y = 0
        }
        return landed
    }
}
