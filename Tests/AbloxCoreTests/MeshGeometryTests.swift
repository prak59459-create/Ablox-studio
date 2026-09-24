import XCTest
@testable import AbloxCore

/// The cylinder and cone that replace iOS 18's `generateCylinder` /
/// `generateCone`.
///
/// Nothing on this machine can render them, and a backwards-wound triangle is
/// invisible from one side rather than obviously broken — so the properties
/// that would otherwise only show up on an iPad are asserted here: every
/// triangle faces outward, every normal is unit length and points the right
/// way, and the silhouette is the size it was asked for.
final class MeshGeometryTests: XCTestCase {

    // MARK: Well-formedness

    func testBothPrimitivesAreWellFormed() {
        XCTAssertTrue(MeshGeometry.cylinder(height: 1, radius: 0.5).isWellFormed)
        XCTAssertTrue(MeshGeometry.cone(height: 1, radius: 0.5).isWellFormed)
    }

    func testWellFormednessRejectsAnOutOfRangeIndex() {
        // Guarding the guard: a check that cannot fail proves nothing about
        // the meshes it passes.
        let broken = MeshGeometry(
            positions: [.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)],
            normals: [.up, .up, .up],
            textureCoordinates: Array(repeating: .init(u: 0, v: 0), count: 3),
            indices: [0, 1, 9]
        )
        XCTAssertFalse(broken.isWellFormed)
    }

    func testWellFormednessRejectsADegenerateTriangle() {
        let broken = MeshGeometry(
            positions: [.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)],
            normals: [.up, .up, .up],
            textureCoordinates: Array(repeating: .init(u: 0, v: 0), count: 3),
            indices: [0, 1, 1]
        )
        XCTAssertFalse(broken.isWellFormed)
    }

    func testWellFormednessRejectsMismatchedBufferLengths() {
        // RealityKit reads these buffers in parallel; a short normals array is
        // a read past the end, not a mesh with some normals missing.
        let broken = MeshGeometry(
            positions: [.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)],
            normals: [.up, .up],
            textureCoordinates: Array(repeating: .init(u: 0, v: 0), count: 3),
            indices: [0, 1, 2]
        )
        XCTAssertFalse(broken.isWellFormed)
    }

    // MARK: Size

    func testTheCylinderIsTheSizeItWasAskedFor() {
        let mesh = MeshGeometry.cylinder(height: 2, radius: 0.5)
        let bounds = mesh.bounds

        XCTAssertEqual(bounds.size.y, 2, accuracy: 1e-5)
        XCTAssertEqual(bounds.center.y, 0, accuracy: 1e-5, "centred on the origin, like RealityKit's own primitives")
        // The ring touches ±radius exactly at 0° and 180°, so the width is the
        // full diameter regardless of how coarse the segmentation is.
        XCTAssertEqual(bounds.size.x, 1, accuracy: 1e-5)
        XCTAssertEqual(bounds.size.z, 1, accuracy: 1e-5)
    }

    func testTheConeIsTheSizeItWasAskedFor() {
        let mesh = MeshGeometry.cone(height: 3, radius: 0.25)
        let bounds = mesh.bounds

        XCTAssertEqual(bounds.size.y, 3, accuracy: 1e-5)
        XCTAssertEqual(bounds.center.y, 0, accuracy: 1e-5)
        XCTAssertEqual(bounds.size.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(bounds.max.y, 1.5, accuracy: 1e-5, "the apex is the top of the box")
    }

    func testEveryVertexIsOnTheSurface() {
        // A stray vertex at the origin would not change the bounds but would
        // drag a triangle through the middle of the shape.
        let radius: Float = 0.5
        let mesh = MeshGeometry.cylinder(height: 1, radius: radius)
        for p in mesh.positions {
            let fromAxis = (p.x * p.x + p.z * p.z).squareRoot()
            let onWall = abs(fromAxis - radius) < 1e-5
            let onCap = abs(abs(p.y) - 0.5) < 1e-5 && fromAxis <= radius + 1e-5
            XCTAssertTrue(onWall || onCap, "vertex \(p) is neither on the wall nor on a cap")
        }
    }

    // MARK: Winding

    func testEveryCylinderTriangleFacesOutward() {
        // The property that matters and cannot be seen from one side: with
        // back-face culling on, an inward-wound triangle is simply not there.
        let mesh = MeshGeometry.cylinder(height: 2, radius: 0.75)
        assertAllTrianglesFaceAwayFromTheCentre(of: mesh)
    }

    func testEveryConeTriangleFacesOutward() {
        let mesh = MeshGeometry.cone(height: 2, radius: 0.75)
        assertAllTrianglesFaceAwayFromTheCentre(of: mesh)
    }

    /// For a convex solid centred on the origin, "outward" has an exact test:
    /// the face normal must not point back toward the centre.
    private func assertAllTrianglesFaceAwayFromTheCentre(
        of mesh: MeshGeometry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for triangle in 0..<mesh.triangleCount {
            let i = triangle * 3
            let a = mesh.positions[Int(mesh.indices[i])]
            let b = mesh.positions[Int(mesh.indices[i + 1])]
            let c = mesh.positions[Int(mesh.indices[i + 2])]
            let centroid = (a + b + c) * (1.0 / 3.0)
            let normal = mesh.faceNormal(ofTriangle: triangle)

            XCTAssertGreaterThan(
                normal.dot(centroid), 0,
                "triangle \(triangle) winds inward — it will be invisible from outside",
                file: file, line: line
            )
        }
    }

    func testNoTriangleHasZeroArea() {
        // A collapsed triangle renders as nothing and can make a normal NaN.
        for mesh in [MeshGeometry.cylinder(height: 1, radius: 0.5), .cone(height: 1, radius: 0.5)] {
            for triangle in 0..<mesh.triangleCount {
                XCTAssertGreaterThan(mesh.faceNormal(ofTriangle: triangle).length, 1e-9)
            }
        }
    }

    // MARK: Normals

    func testEveryNormalIsUnitLength() {
        // Lighting divides by this; a normal of length 2 makes a face twice as
        // bright as the one beside it.
        for mesh in [MeshGeometry.cylinder(height: 1, radius: 0.5), .cone(height: 1, radius: 0.5)] {
            for normal in mesh.normals {
                XCTAssertEqual(normal.length, 1, accuracy: 1e-5)
            }
        }
    }

    // MARK: Sphere (the lighter graphics settings)

    func testTheSphereIsWellFormedTheRightSizeAndFacesOutward() {
        for (rings, segments) in [(16, 24), (8, 12), (2, 3)] {
            let mesh = MeshGeometry.sphere(radius: 0.5, rings: rings, segments: segments)
            XCTAssertTrue(mesh.isWellFormed)
            XCTAssertEqual(mesh.triangleCount, segments * (2 * rings - 2))
            let bounds = mesh.bounds
            XCTAssertEqual(bounds.max.y, 0.5, accuracy: 1e-5)
            XCTAssertEqual(bounds.min.y, -0.5, accuracy: 1e-5)
            XCTAssertEqual(bounds.max.x, 0.5, accuracy: 1e-5)
            assertAllTrianglesFaceAwayFromTheCentre(of: mesh)
            for triangle in 0..<mesh.triangleCount {
                XCTAssertGreaterThan(mesh.faceNormal(ofTriangle: triangle).length, 1e-9)
            }
            for (p, n) in zip(mesh.positions, mesh.normals) {
                XCTAssertEqual(n.length, 1, accuracy: 1e-5)
                XCTAssertEqual(p.length, 0.5, accuracy: 1e-5)
            }
        }
    }

    func testTheCylinderWallShadesAsACurve() {
        // Radial normals, not per-face ones: the difference between a tube and
        // a 24-sided prism.
        let mesh = MeshGeometry.cylinder(height: 1, radius: 0.5)
        for (position, normal) in zip(mesh.positions, mesh.normals) {
            guard abs(normal.y) < 1e-5 else { continue }  // cap vertex
            let radial = Vec3(position.x, 0, position.z).normalized
            XCTAssertEqual(normal.dot(radial), 1, accuracy: 1e-4,
                           "wall normal should point straight out from the axis")
        }
    }

    func testCapNormalsPointAlongTheAxis() {
        let mesh = MeshGeometry.cylinder(height: 1, radius: 0.5)
        for (position, normal) in zip(mesh.positions, mesh.normals) where abs(normal.y) > 1e-5 {
            XCTAssertEqual(abs(normal.y), 1, accuracy: 1e-5)
            // The top cap faces up, the bottom faces down — never the reverse,
            // which would light the lid from inside.
            XCTAssertEqual(normal.y > 0, position.y > 0)
        }
    }

    func testTheConeSlantLeansWithItsShape() {
        // A tall thin cone is nearly vertical-walled, so its normals are nearly
        // horizontal; a flat wide one is the opposite. Getting this backwards
        // is a plausible slip that no silhouette test would catch.
        let tall = MeshGeometry.cone(height: 10, radius: 0.5)
        let flat = MeshGeometry.cone(height: 0.5, radius: 10)

        func averageSlantRise(_ mesh: MeshGeometry) -> Float {
            let slant = zip(mesh.positions, mesh.normals)
                .filter { abs($0.1.y + 1) > 1e-5 }  // drop the base cap
                .map(\.1.y)
            return slant.reduce(0, +) / Float(slant.count)
        }

        XCTAssertLessThan(averageSlantRise(tall), 0.2, "a tall cone's wall is nearly vertical")
        XCTAssertGreaterThan(averageSlantRise(flat), 0.8, "a flat cone's wall is nearly horizontal")
    }

    func testConeNormalsArePerpendicularToTheSlant() {
        let height: Float = 2, radius: Float = 0.6
        let mesh = MeshGeometry.cone(height: height, radius: radius)
        let apex = Vec3(0, height / 2, 0)

        for (position, normal) in zip(mesh.positions, mesh.normals) {
            guard abs(normal.y + 1) > 1e-5, position != apex else { continue }
            let slant = (apex - position).normalized
            XCTAssertEqual(normal.dot(slant), 0, accuracy: 1e-4,
                           "the normal must lie against the surface it describes")
        }
    }

    // MARK: Segmentation

    func testSegmentCountDrivesTriangleCount() {
        // 2 per wall quad + 1 per cap wedge, twice.
        let mesh = MeshGeometry.cylinder(height: 1, radius: 0.5, segments: 12)
        XCTAssertEqual(mesh.triangleCount, 12 * 4)

        // 1 per skirt triangle + 1 per base wedge.
        let cone = MeshGeometry.cone(height: 1, radius: 0.5, segments: 12)
        XCTAssertEqual(cone.triangleCount, 12 * 2)
    }

    func testDegenerateSegmentCountsAreClampedRatherThanCrashing() {
        // A world file, not just our own code, can reach this.
        for segments in [-5, 0, 1, 2] {
            let mesh = MeshGeometry.cylinder(height: 1, radius: 0.5, segments: segments)
            XCTAssertTrue(mesh.isWellFormed, "segments: \(segments) produced an unusable mesh")
            XCTAssertEqual(mesh.triangleCount, 3 * 4, "clamped to the smallest closed shape")
        }
    }

    func testMoreSegmentsConvergeOnTheTrueArea() {
        // The polygonal cross-section is inscribed, so it is always a little
        // under πr² and should close the gap as segments rise. This catches a
        // ring built with the wrong angular step, which every per-vertex test
        // above would happily pass.
        func crossSectionArea(segments: Int) -> Float {
            let r: Float = 1
            let theta = 2 * Float.pi / Float(segments)
            return 0.5 * Float(segments) * r * r * sin(theta)
        }

        let coarse = crossSectionArea(segments: 8)
        let fine = crossSectionArea(segments: 64)
        XCTAssertLessThan(coarse, fine)
        XCTAssertLessThan(fine, Float.pi)
        XCTAssertEqual(fine, Float.pi, accuracy: 0.01)

        // And the mesh really does use that step: opposite vertices on the ring
        // are a full diameter apart only if the angles run 0…2π exactly once.
        let mesh = MeshGeometry.cylinder(height: 1, radius: 1, segments: 8)
        XCTAssertEqual(mesh.bounds.size.x, 2, accuracy: 1e-5)
    }

    // MARK: Texture coordinates

    func testTextureCoordinatesStayInsideTheUnitSquare() {
        for mesh in [MeshGeometry.cylinder(height: 1, radius: 0.5), .cone(height: 1, radius: 0.5)] {
            for uv in mesh.textureCoordinates {
                XCTAssertTrue((0...1).contains(uv.u), "u = \(uv.u) is off the texture")
                XCTAssertTrue((0...1).contains(uv.v), "v = \(uv.v) is off the texture")
            }
        }
    }

    func testTheWallSeamIsDuplicatedRatherThanWrapped() {
        // The first and last wall vertices share a position but must carry
        // u = 0 and u = 1. Sharing one vertex would smear the whole texture
        // backwards across the last segment.
        let mesh = MeshGeometry.cylinder(height: 1, radius: 0.5, segments: 8)
        let first = mesh.positions[0]
        let matching = mesh.positions.indices.filter { mesh.positions[$0] == first }

        XCTAssertGreaterThanOrEqual(matching.count, 2, "no seam duplicate was emitted")
        XCTAssertEqual(Set(matching.map { mesh.textureCoordinates[$0].u }), [0, 1])
    }
}
