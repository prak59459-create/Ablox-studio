import XCTest
@testable import AbloxCore

final class WorldColliderTests: XCTestCase {

    private let body = CharacterBody.default

    /// A 40×1×40 floor whose top surface sits at y = 0.
    private func floorWorld() -> WorldDocument {
        var world = WorldDocument()
        world.blocks = [BlockData(
            name: "Floor",
            shape: .box,
            transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(40, 1, 40))
        )]
        return world
    }

    func testFallingPlayerLandsOnTheFloor() {
        let world = floorWorld()
        var position = Vec3(0, 10, 0)
        var velocity = Vec3(0, -20, 0)

        for _ in 0..<200 {
            let result = WorldCollider.resolve(
                position: position, velocity: velocity, body: body, world: world, deltaTime: 1.0 / 60
            )
            position = result.position
            velocity = result.velocity
            if result.isGrounded { break }
            velocity.y -= 18 * (1.0 / 60)
        }

        XCTAssertEqual(position.y, 0, accuracy: 1e-3, "feet must come to rest on the floor surface")
        XCTAssertEqual(velocity.y, 0, accuracy: 1e-5)
    }

    func testPlayerStandingStillIsGrounded() {
        let world = floorWorld()
        let result = WorldCollider.resolve(
            position: Vec3(0, 0, 0), velocity: .zero, body: body, world: world, deltaTime: 1.0 / 60
        )
        XCTAssertTrue(result.isGrounded, "a stationary player on the floor must be able to jump")
    }

    func testPlayerOverAVoidIsNotGrounded() {
        let world = floorWorld()
        let result = WorldCollider.resolve(
            position: Vec3(500, 0, 0), velocity: .zero, body: body, world: world, deltaTime: 1.0 / 60
        )
        XCTAssertFalse(result.isGrounded)
    }

    func testWallStopsHorizontalMovement() {
        var world = floorWorld()
        // A tall wall at x = 5.
        world.blocks.append(BlockData(
            name: "Wall",
            shape: .box,
            transform: Transform3D(position: Vec3(5, 2, 0), scale: Vec3(1, 4, 10))
        ))

        var position = Vec3(0, 0, 0)
        var velocity = Vec3(10, 0, 0)

        for _ in 0..<120 {
            let result = WorldCollider.resolve(
                position: position, velocity: velocity, body: body, world: world, deltaTime: 1.0 / 60
            )
            position = result.position
            velocity = Vec3(result.velocity.x == 0 ? 0 : 10, result.velocity.y, result.velocity.z)
        }

        // Stopped against the wall's near face (x = 4.5) minus the body radius.
        XCTAssertLessThan(position.x, 4.5)
        XCTAssertGreaterThan(position.x, 3.5)
    }

    func testCeilingStopsAJump() {
        var world = floorWorld()
        world.blocks.append(BlockData(
            name: "Ceiling",
            shape: .box,
            transform: Transform3D(position: Vec3(0, 3, 0), scale: Vec3(10, 1, 10))
        ))

        let result = WorldCollider.resolve(
            position: Vec3(0, 1.0, 0), velocity: Vec3(0, 40, 0), body: body, world: world, deltaTime: 1.0 / 60
        )
        XCTAssertEqual(result.velocity.y, 0, "hitting your head must cancel upward velocity")
        XCTAssertFalse(result.isGrounded, "a ceiling is not a floor")
        XCTAssertLessThanOrEqual(result.position.y + body.height, 2.51)
    }

    func testShallowStepIsWalkedUp() {
        var world = floorWorld()
        // A 0.3m step — below the 0.45m step height.
        world.blocks.append(BlockData(
            name: "Step",
            shape: .box,
            transform: Transform3D(position: Vec3(3, 0.15, 0), scale: Vec3(2, 0.3, 4))
        ))

        var position = Vec3(0, 0, 0)
        for _ in 0..<180 {
            let result = WorldCollider.resolve(
                position: position, velocity: Vec3(5, 0, 0), body: body, world: world, deltaTime: 1.0 / 60
            )
            position = result.position
        }
        XCTAssertGreaterThan(position.x, 3, "a shallow step should be walked over, not bumped into")
        XCTAssertEqual(position.y, 0.3, accuracy: 0.05)
    }

    func testTallStepBlocksMovement() {
        var world = floorWorld()
        // 2m tall — well above the step height, so it is a wall.
        world.blocks.append(BlockData(
            name: "Ledge",
            shape: .box,
            transform: Transform3D(position: Vec3(3, 1, 0), scale: Vec3(2, 2, 4))
        ))

        var position = Vec3(0, 0, 0)
        for _ in 0..<180 {
            let result = WorldCollider.resolve(
                position: position, velocity: Vec3(5, 0, 0), body: body, world: world, deltaTime: 1.0 / 60
            )
            position = result.position
        }
        XCTAssertLessThan(position.x, 2.0, "a 2m ledge must need a jump")
    }

    // MARK: Triggers

    func testCollectibleIsReportedButNotSolid() {
        var world = floorWorld()
        let coin = BlockData(
            name: "Coin",
            transform: Transform3D(position: Vec3(2, 1, 0), scale: Vec3(repeating: 1)),
            behavior: .collectible,
            scoreValue: 10
        )
        world.blocks.append(coin)

        var position = Vec3(0, 0, 0)
        var reported = false
        for _ in 0..<120 {
            let result = WorldCollider.resolve(
                position: position, velocity: Vec3(5, 0, 0), body: body, world: world, deltaTime: 1.0 / 60
            )
            position = result.position
            if result.touchedBlockIDs.contains(coin.id) { reported = true }
        }

        XCTAssertTrue(reported, "walking through a coin must report a touch")
        XCTAssertGreaterThan(position.x, 3, "a coin must not block the player")
    }

    func testHazardIsSolidAndReported() {
        var world = floorWorld()
        let lava = BlockData(
            name: "Lava",
            transform: Transform3D(position: Vec3(0, 0.2, 0), scale: Vec3(4, 0.4, 4)),
            behavior: .hazard
        )
        world.blocks.append(lava)

        let result = WorldCollider.resolve(
            position: Vec3(0, 0.4, 0), velocity: Vec3(0, -1, 0), body: body, world: world, deltaTime: 1.0 / 60
        )
        XCTAssertTrue(result.touchedBlockIDs.contains(lava.id), "standing in lava must register")
        XCTAssertTrue(result.isGrounded, "a hazard is a surface you land on, not one you fall through")
    }

    func testInertBlocksAreNeverReported() {
        var world = floorWorld()
        let scenery = BlockData(name: "Rock", transform: Transform3D(position: Vec3(0, 1, 0)))
        world.blocks.append(scenery)

        let result = WorldCollider.resolve(
            position: Vec3(0, 0, 0), velocity: .zero, body: body, world: world, deltaTime: 1.0 / 60
        )
        XCTAssertFalse(result.touchedBlockIDs.contains(scenery.id))
    }

    func testNonCollidingBlocksAreIgnored() {
        var world = floorWorld()
        world.blocks.append(BlockData(
            name: "Ghost",
            transform: Transform3D(position: Vec3(2, 1, 0), scale: Vec3(2, 4, 2)),
            hasCollision: false
        ))

        var position = Vec3(0, 0, 0)
        for _ in 0..<120 {
            position = WorldCollider.resolve(
                position: position, velocity: Vec3(5, 0, 0), body: body, world: world, deltaTime: 1.0 / 60
            ).position
        }
        XCTAssertGreaterThan(position.x, 4, "a non-colliding block must not stop anyone")
    }

    func testInvisibleBlocksDoNotCollide() {
        var world = floorWorld()
        world.blocks.append(BlockData(
            name: "Hidden",
            transform: Transform3D(position: Vec3(2, 2, 0), scale: Vec3(2, 4, 2)),
            isVisible: false
        ))

        var position = Vec3(0, 0, 0)
        for _ in 0..<120 {
            position = WorldCollider.resolve(
                position: position, velocity: Vec3(5, 0, 0), body: body, world: world, deltaTime: 1.0 / 60
            ).position
        }
        XCTAssertGreaterThan(position.x, 4, "a door hidden by a rule must actually open")
    }

    // MARK: Robustness

    func testResolutionIsDeterministic() {
        // The whole reason collision lives in core rather than RealityKit:
        // two devices must compute the same answer from the same inputs.
        var world = floorWorld()
        world.blocks.append(BlockData(name: "Wall", transform: Transform3D(position: Vec3(3, 2, 0), scale: Vec3(1, 4, 8))))

        let a = WorldCollider.resolve(position: Vec3(0, 0, 0), velocity: Vec3(9, -3, 1), body: body, world: world, deltaTime: 1.0 / 60)
        let b = WorldCollider.resolve(position: Vec3(0, 0, 0), velocity: Vec3(9, -3, 1), body: body, world: world, deltaTime: 1.0 / 60)
        XCTAssertEqual(a, b)
    }

    func testHugeTimeStepIsClamped() {
        let world = floorWorld()
        // 30 seconds of "one frame" must not tunnel the player through the floor.
        let result = WorldCollider.resolve(
            position: Vec3(0, 5, 0), velocity: Vec3(0, -100, 0), body: body, world: world, deltaTime: 30
        )
        XCTAssertGreaterThan(result.position.y, -20)
    }

    func testEmptyWorldDoesNotCrash() {
        let result = WorldCollider.resolve(
            position: Vec3(0, 5, 0), velocity: Vec3(1, -1, 1), body: body, world: WorldDocument(), deltaTime: 1.0 / 60
        )
        XCTAssertFalse(result.isGrounded)
        XCTAssertTrue(result.touchedBlockIDs.isEmpty)
        XCTAssertTrue(result.position.isFinite)
    }

    func testPlayerNeverEndsInsideASolid() {
        var world = floorWorld()
        world.blocks.append(BlockData(name: "Pillar", transform: Transform3D(position: Vec3(0, 2, 0), scale: Vec3(2, 4, 2))))

        // Drive the player at the pillar from several directions and assert
        // they never finish overlapping it.
        let pillarBox = world.worldBounds(of: world.blocks[1].id)!
        for angle in stride(from: Float(0), to: 360, by: 30) {
            let direction = Quat.yaw(degrees: angle).act(Vec3(1, 0, 0))
            var position = direction * -6
            position.y = 0
            for _ in 0..<200 {
                let result = WorldCollider.resolve(
                    position: position, velocity: direction * 8, body: body, world: world, deltaTime: 1.0 / 60
                )
                position = result.position
            }
            // `penetrates`, not `intersects`: coming to rest exactly flush
            // against the pillar's face is the desired outcome, and reads as
            // touching. What must never happen is ending up *inside* it.
            XCTAssertFalse(
                pillarBox.penetrates(body.bounds(at: position)),
                "approaching from \(angle)° ended inside the pillar at \(position)"
            )
        }
    }
}
