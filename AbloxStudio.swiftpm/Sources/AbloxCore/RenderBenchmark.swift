import Foundation

/// A busy world for measuring how fast the 3D view draws, built the same
/// way every time: a town of about three thousand parts, sixty characters
/// walking about (a see-through root with fourteen parts each, as the
/// catalogue's characters are), a dance floor changing colour, spinning
/// signs, lamps and moving platforms.
///
/// The launch check opens it on a simulator (`-AbloxPlayBenchmark YES`) and
/// reads the frame rate the game prints; nobody meets it in the app.
public enum RenderBenchmark {

    public static let worldID = UUID(uuidString: "AB10B0E5-0000-4000-8000-000000000B0E")!
    public static let walkerCount = 60
    public static let partsPerWalker = 14
    public static let discoTiles = 36

    public static func world() -> WorldDocument {
        let built = Date(timeIntervalSince1970: 1_790_000_000)
        var world = WorldDocument(id: worldID, name: "Render Benchmark", authorName: "Ablox",
                                  createdAt: built, modifiedAt: built)
        var random = Dice(seed: 7)
        var blocks: [BlockData] = []
        blocks.reserveCapacity(3_200)

        func part(_ name: String, _ shape: BlockShape = .box, at position: Vec3, size: Vec3,
                  color: String, material: MaterialKind = .plastic, parent: UUID? = nil) -> BlockData {
            BlockData(name: name, shape: shape, transform: Transform3D(position: position, scale: size),
                      color: ColorRGBA(hex: color) ?? .defaultBlock, material: material, parentID: parent)
        }

        // The ground: 20 × 20 tiles of 10 m.
        for x in 0..<20 {
            for z in 0..<20 {
                let grass = (x + z) % 2 == 0
                blocks.append(part("Ground", at: Vec3(Float(x) * 10 - 95, -0.5, Float(z) * 10 - 95), size: Vec3(10, 1, 10),
                                   color: grass ? "#4C9A4A" : "#D8C48A", material: grass ? .grass : .sand))
            }
        }

        // Houses on an 8 × 8 grid, with gaps for streets.
        let wallColors = ["#E5E7EB", "#FDE68A", "#FCA5A5", "#93C5FD", "#C4B5FD"]
        for gx in 0..<8 {
            for gz in 0..<8 {
                let centre = Vec3(Float(gx) * 22 - 77, 0, Float(gz) * 22 - 77)
                guard abs(centre.x) > 12 || abs(centre.z) > 12 else { continue }
                let wall = wallColors[random.next(wallColors.count)]
                let height = Float(4 + random.next(4))
                blocks.append(part("Wall", at: centre + Vec3(0, height / 2, -4), size: Vec3(8, height, 0.4), color: wall, material: .brick))
                blocks.append(part("Wall", at: centre + Vec3(0, height / 2, 4), size: Vec3(8, height, 0.4), color: wall, material: .brick))
                blocks.append(part("Wall", at: centre + Vec3(-4, height / 2, 0), size: Vec3(0.4, height, 8), color: wall, material: .brick))
                blocks.append(part("Wall", at: centre + Vec3(4, height / 2, 0), size: Vec3(0.4, height, 8), color: wall, material: .brick))
                blocks.append(part("Roof", .cone, at: centre + Vec3(0, height + 1.5, 0), size: Vec3(10, 3, 10), color: "#B91C1C"))
                for side in [Float(-2.2), 2.2] {
                    blocks.append(part("Window", at: centre + Vec3(side, height * 0.6, 4.25), size: Vec3(1.4, 1.4, 0.1), color: "#BFDBFE", material: .metal))
                    blocks.append(part("Window", at: centre + Vec3(side, height * 0.6, -4.25), size: Vec3(1.4, 1.4, 0.1), color: "#BFDBFE", material: .metal))
                }
                blocks.append(part("Door", at: centre + Vec3(0, 1.1, 4.25), size: Vec3(1.2, 2.2, 0.1), color: "#7C4A21", material: .wood))
                blocks.append(part("Chimney", at: centre + Vec3(2.5, height + 2, 2), size: Vec3(0.8, 2, 0.8), color: "#6B7280", material: .stone))
            }
        }

        // Trees, crates and fences.
        for _ in 0..<160 {
            let at = Vec3(random.float(-95, 95), 0, random.float(-95, 95))
            blocks.append(part("Trunk", .cylinder, at: at + Vec3(0, 1.5, 0), size: Vec3(0.5, 3, 0.5), color: "#7C4A21", material: .wood))
            blocks.append(part("Leaves", .sphere, at: at + Vec3(0, 3.8, 0), size: Vec3(2.6, 2.6, 2.6), color: "#2F855A", material: .grass))
        }
        for _ in 0..<300 {
            let at = Vec3(random.float(-95, 95), 0.5, random.float(-95, 95))
            blocks.append(part("Crate", at: at, size: Vec3(1, 1, 1), color: "#B7791F", material: .wood))
        }
        for i in 0..<120 {
            let x = Float(i) * 1.6 - 96
            blocks.append(part("Fence", at: Vec3(x, 0.6, -98), size: Vec3(1.5, 1.2, 0.15), color: "#F5F5F4", material: .wood))
        }

        // A dance floor in the middle, changed by the script twice a second.
        for x in 0..<6 {
            for z in 0..<6 {
                var tile = part("Disco", at: Vec3(Float(x) * 2 - 5, 0.05, Float(z) * 2 - 5), size: Vec3(1.9, 0.1, 1.9),
                                color: "#A855F7", material: .neon)
                tile.tags = ["disco"]
                blocks.append(tile)
            }
        }

        var spawn = part("Spawn", at: Vec3(0, 0.1, 9), size: Vec3(3, 0.2, 3), color: "#22C55E")
        spawn.behavior = .spawn
        blocks.append(spawn)

        // Signs that spin, lamps and two moving platforms.
        for i in 0..<20 {
            var sign = part("Sign", at: Vec3(Float(i % 10) * 6 - 27, 3, i < 10 ? -14 : 14), size: Vec3(2, 1, 0.2), color: "#FACC15")
            sign.animation = BlockAnimation(kind: i % 2 == 0 ? .spin : .sway)
            sign.label = BlockLabel(text: "Sign \(i + 1)")
            blocks.append(sign)
        }
        for i in 0..<6 {
            var lamp = part("Lamp", .sphere, at: Vec3(Float(i) * 8 - 20, 4, 0), size: Vec3(0.6, 0.6, 0.6), color: "#FEF3C7", material: .neon)
            lamp.light = BlockLight()
            blocks.append(lamp)
        }
        for i in 0..<2 {
            var platform = part("Platform", at: Vec3(Float(i) * 10 - 5, 1, 20), size: Vec3(3, 0.4, 3), color: "#38BDF8")
            platform.behavior = .elevator
            platform.gimmick.moveOffset = Vec3(0, 3, 0)
            blocks.append(platform)
        }

        // Characters: a see-through root and its parts, walked by the script.
        let bodyColors = ["#F97316", "#22D3EE", "#F472B6", "#A3E635", "#FDE047", "#818CF8"]
        for i in 0..<walkerCount {
            let at = Vec3(Float(i % 10) * 8 - 36, 0, Float(i / 10) * 8 - 30)
            var root = part("Walker", at: at, size: Vec3(1, 1, 1), color: "#FFFFFF")
            root.color.a = 0
            root.hasCollision = false
            root.tags = ["walker"]
            if i % 3 == 0 { root.label = BlockLabel(text: "Walker \(i + 1)") }
            blocks.append(root)
            let body = bodyColors[i % bodyColors.count]
            let id = root.id
            blocks.append(part("Body", at: Vec3(0, 1.2, 0), size: Vec3(1, 1.1, 0.6), color: body, parent: id))
            blocks.append(part("Belly", at: Vec3(0, 1.1, 0.31), size: Vec3(0.6, 0.6, 0.05), color: "#FFFFFF", parent: id))
            blocks.append(part("Head", .sphere, at: Vec3(0, 2.15, 0), size: Vec3(0.9, 0.9, 0.9), color: body, parent: id))
            blocks.append(part("Eye", .sphere, at: Vec3(-0.2, 2.25, 0.4), size: Vec3(0.18, 0.18, 0.1), color: "#111827", parent: id))
            blocks.append(part("Eye", .sphere, at: Vec3(0.2, 2.25, 0.4), size: Vec3(0.18, 0.18, 0.1), color: "#111827", parent: id))
            blocks.append(part("Mouth", at: Vec3(0, 1.98, 0.43), size: Vec3(0.3, 0.06, 0.05), color: "#111827", parent: id))
            blocks.append(part("Arm", .cylinder, at: Vec3(-0.65, 1.25, 0), size: Vec3(0.25, 0.9, 0.25), color: body, parent: id))
            blocks.append(part("Arm", .cylinder, at: Vec3(0.65, 1.25, 0), size: Vec3(0.25, 0.9, 0.25), color: body, parent: id))
            blocks.append(part("Hand", .sphere, at: Vec3(-0.65, 0.75, 0), size: Vec3(0.28, 0.28, 0.28), color: "#FDE7D3", parent: id))
            blocks.append(part("Hand", .sphere, at: Vec3(0.65, 0.75, 0), size: Vec3(0.28, 0.28, 0.28), color: "#FDE7D3", parent: id))
            blocks.append(part("Leg", at: Vec3(-0.25, 0.35, 0), size: Vec3(0.35, 0.7, 0.35), color: "#1F2937", parent: id))
            blocks.append(part("Leg", at: Vec3(0.25, 0.35, 0), size: Vec3(0.35, 0.7, 0.35), color: "#1F2937", parent: id))
            blocks.append(part("Hat", .cone, at: Vec3(0, 2.8, 0), size: Vec3(0.7, 0.6, 0.7), color: "#DC2626", parent: id))
            blocks.append(part("Bobble", .sphere, at: Vec3(0, 3.15, 0), size: Vec3(0.2, 0.2, 0.2), color: "#FFFFFF", parent: id))
        }

        world.blocks = blocks
        world.modifiedAt = built
        world.scripts = [ScriptFile(name: "main", source: script)]
        return world
    }

    /// Walks every character to and fro ten times a second and repaints the
    /// dance floor twice a second: the changes a busy game sends.
    static let script = """
    let dir = 1
    let beat = 0
    let walkers = []
    let disco = []
    let colors = ["red", "orange", "yellow", "green", "blue", "purple"]

    on start()
      walkers = blocks("walker")
      disco = blocks("disco")
      every(2, func() dir = -dir end)
      every(0.5, func()
        beat = beat + 1
        for d in disco do d.color = colors[beat % 6 + 1] end
      end)
    end

    on tick(dt)
      for w in walkers do w.move(dir * 1.5 * dt, 0, 0, 0) end
    end
    """

    /// The same "random" town every time.
    private struct Dice {
        var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next(_ count: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(Swift.max(1, count)))
        }

        mutating func float(_ low: Float, _ high: Float) -> Float {
            low + (high - low) * Float(next(10_000)) / 10_000
        }
    }
}
