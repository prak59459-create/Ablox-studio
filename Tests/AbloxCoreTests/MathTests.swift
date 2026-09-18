import XCTest
@testable import AbloxCore

final class MathTests: XCTestCase {

    // MARK: Vec3

    func testVectorArithmetic() {
        let a = Vec3(1, 2, 3)
        let b = Vec3(4, 5, 6)
        XCTAssertEqual(a + b, Vec3(5, 7, 9))
        XCTAssertEqual(b - a, Vec3(3, 3, 3))
        XCTAssertEqual(a * 2, Vec3(2, 4, 6))
        XCTAssertEqual(a.dot(b), 32)
        XCTAssertEqual(a.cross(b), Vec3(-3, 6, -3))
    }

    func testNormalizedOfZeroVectorIsZeroNotNaN() {
        let n = Vec3.zero.normalized
        XCTAssertEqual(n, .zero)
        XCTAssertTrue(n.isFinite)
    }

    func testHorizontalDistanceIgnoresHeight() {
        let ground = Vec3(3, 0, 4)
        let tower = Vec3(0, 100, 0)
        XCTAssertEqual(ground.horizontalDistance(to: tower), 5, accuracy: 1e-5)
        XCTAssertEqual(ground.distance(to: tower), (9 + 10000 + 16 as Float).squareRoot(), accuracy: 1e-3)
    }

    func testGridSnapping() {
        let v = Vec3(1.2, -0.4, 2.6)
        XCTAssertEqual(v.snapped(toGridOf: 0.5), Vec3(1.0, -0.5, 2.5))
        // A non-positive step means "snapping is off", not a divide by zero.
        XCTAssertEqual(v.snapped(toGridOf: 0), v)
        XCTAssertEqual(v.snapped(toGridOf: -1), v)
    }

    // MARK: Quat

    func testEulerRoundTrip() {
        for angles in [Vec3(0, 0, 0), Vec3(30, 45, 60), Vec3(-15, 170, 5), Vec3(0, -90, 0)] {
            let q = Quat.euler(degrees: angles)
            let back = q.eulerDegrees
            let reconstructed = Quat.euler(degrees: back)
            // Compare rotations, not angle triples: different triples can name
            // the same rotation.
            let probe = Vec3(0.3, 0.6, -0.7)
            let lhs = q.act(probe)
            let rhs = reconstructed.act(probe)
            XCTAssertEqual(lhs.x, rhs.x, accuracy: 1e-3, "pitch/yaw/roll \(angles)")
            XCTAssertEqual(lhs.y, rhs.y, accuracy: 1e-3, "pitch/yaw/roll \(angles)")
            XCTAssertEqual(lhs.z, rhs.z, accuracy: 1e-3, "pitch/yaw/roll \(angles)")
        }
    }

    func testGimbalLockDoesNotProduceNaN() {
        let q = Quat.euler(degrees: Vec3(90, 33, 12))
        let e = q.eulerDegrees
        XCTAssertTrue(e.isFinite)
        XCTAssertEqual(abs(e.x), 90, accuracy: 0.5)
        XCTAssertEqual(e.z, 0, accuracy: 1e-4, "roll folds into yaw at the singularity")
    }

    func testQuaternionRotatesVector() {
        let yaw90 = Quat.yaw(degrees: 90)
        let rotated = yaw90.act(Vec3(0, 0, -1))
        // +Y yaw of 90° takes -Z (forward) to -X.
        XCTAssertEqual(rotated.x, -1, accuracy: 1e-5)
        XCTAssertEqual(rotated.y, 0, accuracy: 1e-5)
        XCTAssertEqual(rotated.z, 0, accuracy: 1e-5)
    }

    func testQuaternionCompositionOrder() {
        // `a * b` must apply b first.
        let yaw = Quat.yaw(degrees: 90)
        let pitch = Quat(axis: .right, angle: .pi / 2)
        let composed = yaw * pitch
        let sequential = yaw.act(pitch.act(Vec3(0, 0, -1)))
        let combined = composed.act(Vec3(0, 0, -1))
        XCTAssertEqual(combined.x, sequential.x, accuracy: 1e-5)
        XCTAssertEqual(combined.y, sequential.y, accuracy: 1e-5)
        XCTAssertEqual(combined.z, sequential.z, accuracy: 1e-5)
    }

    func testSlerpTakesShortestArc() {
        let a = Quat.yaw(degrees: -170)
        let b = Quat.yaw(degrees: 170)
        let mid = Quat.slerp(a, b, 0.5)
        let facing = mid.act(Vec3(0, 0, -1))
        // The short way through 180°, not through 0°.
        XCTAssertEqual(facing.z, 1, accuracy: 1e-3)
        XCTAssertEqual(facing.x, 0, accuracy: 1e-3)
    }

    func testInverseUndoesRotation() {
        let q = Quat.euler(degrees: Vec3(20, 50, -35))
        let v = Vec3(1, 2, 3)
        let round = q.inverse.act(q.act(v))
        XCTAssertEqual(round.x, v.x, accuracy: 1e-4)
        XCTAssertEqual(round.y, v.y, accuracy: 1e-4)
        XCTAssertEqual(round.z, v.z, accuracy: 1e-4)
    }

    // MARK: Transform

    func testTransformConcatenationMatchesManualComposition() {
        let parent = Transform3D(position: Vec3(10, 0, 0), rotation: .yaw(degrees: 90), scale: Vec3(repeating: 2))
        let child = Transform3D(position: Vec3(0, 0, -1), rotation: .identity, scale: Vec3(repeating: 0.5))
        let world = child.concatenating(parent: parent)

        // Child sits 1 unit forward of the parent, parent is scaled 2x and
        // yawed 90°, so the child lands 2 units along -X from the parent.
        XCTAssertEqual(world.position.x, 8, accuracy: 1e-4)
        XCTAssertEqual(world.position.y, 0, accuracy: 1e-4)
        XCTAssertEqual(world.position.z, 0, accuracy: 1e-4)
        XCTAssertEqual(world.scale.x, 1, accuracy: 1e-5)
    }

    func testInverseTransformRoundTrips() {
        let t = Transform3D(position: Vec3(3, -2, 7), rotation: .euler(degrees: Vec3(10, 40, 0)), scale: Vec3(2, 1, 0.5))
        let local = Vec3(0.4, -1.2, 3)
        let back = t.inverseTransform(point: t.transform(point: local))
        XCTAssertEqual(back.x, local.x, accuracy: 1e-3)
        XCTAssertEqual(back.y, local.y, accuracy: 1e-3)
        XCTAssertEqual(back.z, local.z, accuracy: 1e-3)
    }

    func testInverseTransformSurvivesZeroScale() {
        let t = Transform3D(position: .zero, rotation: .identity, scale: Vec3(1, 0, 1))
        let result = t.inverseTransform(point: Vec3(1, 5, 1))
        XCTAssertTrue(result.isFinite, "a flattened axis must not yield infinity")
        XCTAssertEqual(result.y, 0)
    }

    // MARK: Bounds and rays

    func testRayHitsBox() {
        let box = BoundingBox(center: Vec3(0, 0, -5), size: Vec3(2, 2, 2))
        let ray = Ray(origin: .zero, direction: .forward)
        let hit = ray.intersects(box)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!, 4, accuracy: 1e-4)
    }

    func testRayMissesBox() {
        let box = BoundingBox(center: Vec3(0, 50, -5), size: Vec3(2, 2, 2))
        XCTAssertNil(Ray(origin: .zero, direction: .forward).intersects(box))
    }

    func testRayParallelToSlabInsideStillHits() {
        // Travelling along +X, level with a wide flat box.
        let box = BoundingBox(center: Vec3(5, 0, 0), size: Vec3(2, 2, 2))
        let ray = Ray(origin: .zero, direction: Vec3(1, 0, 0))
        XCTAssertEqual(ray.intersects(box)!, 4, accuracy: 1e-4)
    }

    func testRayStartingInsideBoxReportsZero() {
        let box = BoundingBox(center: .zero, size: Vec3(4, 4, 4))
        XCTAssertEqual(Ray(origin: .zero, direction: .forward).intersects(box)!, 0, accuracy: 1e-6)
    }

    func testGroundPlaneIntersection() {
        let ray = Ray(origin: Vec3(0, 10, 0), direction: Vec3(0, -1, 0))
        XCTAssertEqual(ray.intersectionWithHorizontalPlane(atHeight: 0)!, 10, accuracy: 1e-5)
        // Looking up never meets the floor.
        let up = Ray(origin: Vec3(0, 10, 0), direction: .up)
        XCTAssertNil(up.intersectionWithHorizontalPlane(atHeight: 0))
        // Exactly horizontal never meets it either.
        let flat = Ray(origin: Vec3(0, 10, 0), direction: Vec3(1, 0, 0))
        XCTAssertNil(flat.intersectionWithHorizontalPlane(atHeight: 0))
    }

    func testBoundingBoxUnion() {
        let a = BoundingBox(center: .zero, size: Vec3(2, 2, 2))
        let b = BoundingBox(center: Vec3(10, 0, 0), size: Vec3(2, 2, 2))
        let union = a.union(b)
        XCTAssertEqual(union.min.x, -1, accuracy: 1e-5)
        XCTAssertEqual(union.max.x, 11, accuracy: 1e-5)
        XCTAssertNil(BoundingBox.containing([BoundingBox]()))
        XCTAssertEqual(BoundingBox.containing([a, b]), union)
    }

    // MARK: Angles

    func testNormalizeDegrees() {
        XCTAssertEqual(normalizeDegrees(0), 0)
        XCTAssertEqual(normalizeDegrees(180), 180)
        XCTAssertEqual(normalizeDegrees(-180), 180, "the half-open range keeps 180 canonical")
        XCTAssertEqual(normalizeDegrees(190), -170, accuracy: 1e-4)
        XCTAssertEqual(normalizeDegrees(720 + 45), 45, accuracy: 1e-4)
    }

    func testAngularDeltaTakesShortWay() {
        XCTAssertEqual(angularDelta(from: 170, to: -170), 20, accuracy: 1e-4)
        XCTAssertEqual(angularDelta(from: -170, to: 170), -20, accuracy: 1e-4)
    }

    // MARK: Color

    func testHexParsing() {
        XCTAssertEqual(ColorRGBA(hex: "#FFFFFF"), .white)
        XCTAssertEqual(ColorRGBA(hex: "000000"), .black)
        XCTAssertEqual(ColorRGBA(hex: "#FFF"), .white, "shorthand expands nibbles")
        XCTAssertNil(ColorRGBA(hex: "#GGG"))
        XCTAssertNil(ColorRGBA(hex: "#FFFFF"))
        XCTAssertNil(ColorRGBA(hex: ""))
    }

    func testHexRoundTrip() {
        let color = ColorRGBA(hex: "#22D3EE")!
        XCTAssertEqual(color.hexString, "#22D3EE")
        // Translucent colors keep their alpha byte.
        XCTAssertEqual(color.withAlpha(0.5).hexString.count, 9)
    }

    func testColorLerpClampsT() {
        let mid = ColorRGBA.lerp(.black, .white, 0.5)
        XCTAssertEqual(mid.r, 0.5, accuracy: 1e-5)
        XCTAssertEqual(ColorRGBA.lerp(.black, .white, 5).r, 1, accuracy: 1e-5)
        XCTAssertEqual(ColorRGBA.lerp(.black, .white, -5).r, 0, accuracy: 1e-5)
    }

    func testPaletteEntriesAllParsed() {
        XCTAssertEqual(ColorRGBA.palette.count, 12)
        XCTAssertTrue(ColorRGBA.palette.allSatisfy { $0.isOpaque })
    }
}
