import Foundation

/// Who is near whom, when a game has a crowd.
///
/// Last Survivor Games keeps a hundred people and NPCs on one field. Every
/// NPC looked at every other one each step, and bumped into all of them,
/// so the iPad had a hundred times a hundred checks a frame and could hardly
/// move. The grid sorts everyone into squares once a step; a question then
/// only looks at the squares around it, and only the nearest few count.
public struct CrowdGrid<ID: Hashable> {

    /// The nearest characters anyone bumps into. Further ones are behind
    /// these anyway.
    public static var limit: Int { 6 }

    private struct Square: Hashable {
        var x: Int
        var z: Int
    }

    public let cell: Float
    private var squares: [Square: [(id: ID, position: Vec3)]] = [:]

    public init(_ members: [(id: ID, position: Vec3)], cell: Float = WorldCollider.characterReach) {
        self.cell = Swift.max(cell, 0.5)
        for member in members {
            squares[square(of: member.position), default: []].append(member)
        }
    }

    private func square(of point: Vec3) -> Square {
        Square(x: Int((point.x / cell).rounded(.down)), z: Int((point.z / cell).rounded(.down)))
    }

    /// Up to `limit` members within `reach` of `point`, nearest first,
    /// leaving out `except`.
    public func nearest(to point: Vec3, within reach: Float, limit: Int = Self.limit,
                        except: ID? = nil) -> [(id: ID, position: Vec3)] {
        guard limit > 0, reach > 0, point.x.isFinite, point.z.isFinite else { return [] }
        let centre = square(of: point)
        let span = Int((reach / cell).rounded(.up))
        let reachSquared = reach * reach
        // The nearest so far, kept in order: only a few are wanted, so
        // putting each in its place is cheaper than sorting everyone.
        var found: [(id: ID, position: Vec3, distance: Float)] = []
        found.reserveCapacity(Swift.min(limit, 16))
        for dx in -span...span {
            for dz in -span...span {
                guard let members = squares[Square(x: centre.x + dx, z: centre.z + dz)] else { continue }
                for member in members {
                    let offset = member.position - point
                    let distance = offset.x * offset.x + offset.y * offset.y + offset.z * offset.z
                    guard distance < reachSquared else { continue }
                    if found.count == limit, let last = found.last, distance >= last.distance { continue }
                    if let except, member.id == except { continue }
                    var at = found.count
                    while at > 0, found[at - 1].distance > distance { at -= 1 }
                    found.insert((member.id, member.position, distance), at: at)
                    if found.count > limit { found.removeLast() }
                }
            }
        }
        return found.map { ($0.id, $0.position) }
    }
}
