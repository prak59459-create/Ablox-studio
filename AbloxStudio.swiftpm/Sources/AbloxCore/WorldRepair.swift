import Foundation

/// Mends a world file that would otherwise misbehave: a part with no size
/// or a position that is not a number, two parts sharing an id, a part
/// whose parent is gone or is its own grandchild.
///
/// Such a file does not come from Studio, but it can come from a hand-edit,
/// a half-written save, or an older build's bug, and one bad number is
/// enough to send the camera to infinity or hang the renderer. Every world
/// read passes through here (`WorldDocument.decoded(from:)`), and a world
/// with nothing wrong comes out exactly as it went in.
public enum WorldRepair {

    /// What was mended, for the problem reports.
    public struct Report: Hashable, Sendable {
        public var badNumbers = 0
        public var badSizes = 0
        public var duplicateIDs = 0
        public var brokenParents = 0
        public var badColours = 0

        public var total: Int { badNumbers + badSizes + duplicateIDs + brokenParents + badColours }
        public var isEmpty: Bool { total == 0 }

        public var summary: String {
            var parts: [String] = []
            if badNumbers > 0 { parts.append(L("{} positions or turns that were not numbers", badNumbers)) }
            if badSizes > 0 { parts.append(L("{} sizes out of range", badSizes)) }
            if duplicateIDs > 0 { parts.append(L("{} parts sharing an id", duplicateIDs)) }
            if brokenParents > 0 { parts.append(L("{} parts in a missing or looping group", brokenParents)) }
            if badColours > 0 { parts.append(L("{} colours out of range", badColours)) }
            return parts.joined(separator: ", ")
        }
    }

    /// The largest a part may be on any side, as Studio allows.
    public static let largestSize: Float = 2_000
    public static let smallestSize: Float = 0.01
    /// Further from the middle than this is not a place anyone can go.
    public static let farthest: Float = 1_000_000

    public static func repaired(_ world: WorldDocument) -> (world: WorldDocument, report: Report) {
        var report = Report()
        var blocks = world.blocks
        var seen = Set<UUID>()
        seen.reserveCapacity(blocks.count)

        for index in blocks.indices {
            var block = blocks[index]
            let original = block

            if !seen.insert(block.id).inserted {
                block.id = UUID()
                seen.insert(block.id)
                report.duplicateIDs += 1
            }

            var transform = block.transform
            if !isUsable(transform.position) {
                transform.position = .zero
                report.badNumbers += 1
            }
            let q = transform.rotation
            if ![q.x, q.y, q.z, q.w].allSatisfy(\.isFinite) || q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w < 1e-6 {
                transform.rotation = .identity
                report.badNumbers += 1
            }
            let s = transform.scale
            let fixedScale = Vec3(sizeFixed(s.x), sizeFixed(s.y), sizeFixed(s.z))
            if fixedScale != s {
                transform.scale = fixedScale
                report.badSizes += 1
            }
            block.transform = transform

            let c = block.color
            let fixedColour = ColorRGBA(r: unit(c.r), g: unit(c.g), b: unit(c.b), a: unit(c.a, fallback: 1))
            if fixedColour != c {
                block.color = fixedColour
                report.badColours += 1
            }

            if block != original { blocks[index] = block }
        }

        // Parents: gone, or round in a loop. Checked after the ids are
        // unique, so "gone" means gone.
        let ids = Set(blocks.map(\.id))
        var parentOf = Dictionary(blocks.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        for index in blocks.indices {
            guard let parent = blocks[index].parentID else { continue }
            var broken = !ids.contains(parent) || parent == blocks[index].id
            if !broken {
                // Walk up; meeting this part again is a loop.
                var visited: Set<UUID> = [blocks[index].id]
                var next: UUID? = parent
                while let current = next {
                    if !visited.insert(current).inserted { broken = true; break }
                    next = parentOf[current] ?? nil
                }
            }
            if broken {
                blocks[index].parentID = nil
                parentOf[blocks[index].id] = .some(nil)
                report.brokenParents += 1
            }
        }

        guard !report.isEmpty else { return (world, report) }
        var mended = world
        mended.blocks = blocks
        return (mended, report)
    }

    static func isUsable(_ v: Vec3) -> Bool {
        [v.x, v.y, v.z].allSatisfy { $0.isFinite && abs($0) <= farthest }
    }

    static func sizeFixed(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return Swift.min(largestSize, Swift.max(smallestSize, abs(value)))
    }

    static func unit(_ value: Float, fallback: Float = 0) -> Float {
        guard value.isFinite else { return fallback }
        return Swift.min(1, Swift.max(0, value))
    }
}
