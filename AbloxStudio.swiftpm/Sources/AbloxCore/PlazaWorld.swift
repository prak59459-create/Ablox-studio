import Foundation

/// The Plaza (Ablox NEXT, step 5): a little world to walk around between
/// games. A fountain in the middle, trees and lamps round the edge, and a
/// ring of doors facing the fountain, each with a game's cover on it —
/// today's pick, what was played last, the most popular — and two doors of
/// the menu's own: the closet and every game. Walking into a door opens
/// what is behind it. The browser version builds the same Plaza
/// (web/src/app/plaza.ts in AbloxGames).
public enum PlazaWorld {

    /// Where a door goes.
    public enum Door: Hashable, Sendable {
        /// A game's page in the list, by its listing id.
        case game(String)
        /// Me → Closet.
        case closet
        /// Play → Games.
        case allGames
    }

    public struct Plaza: Sendable {
        public var world: WorldDocument
        /// The doors' blocks: walking into one opens what it says.
        public var doors: [UUID: Door]
    }

    /// One fixed id, so the Plaza's saves and leaderboards (it has none)
    /// never mix with a game's.
    public static let worldID = UUID(uuidString: "AB10C000-0000-4000-8000-0000000F1A2A")!

    /// The games behind the doors: today's pick, the last few played, then
    /// the most popular, then the rest; no game twice.
    public static func games(from listings: [GameListing], recent: [String], count: Int = 8, on date: Date = Date()) -> [GameListing] {
        var out: [GameListing] = []
        func add(_ g: GameListing?) {
            guard let g, out.count < count, !out.contains(where: { $0.id == g.id }) else { return }
            out.append(g)
        }
        add(CatalogueShelf.dailyPick(from: listings, on: date))
        // Three games played lately: a game played twice, or one no longer in the list, does not use up a door.
        var lately = 0
        for id in recent where lately < 3 {
            let before = out.count
            add(listings.first { $0.id == id })
            if out.count > before { lately += 1 }
        }
        for g in listings where g.tags.contains("top20") { add(g) }
        for g in listings { add(g) }
        return out
    }

    private static let doorColours = ["#22D3EE", "#F472B6", "#FFC93C", "#4ADE80", "#A855F7", "#FF9F1C", "#38BDF8", "#FB7185", "#A3E635", "#F59E0B"]

    private static func hex(_ h: String) -> ColorRGBA { ColorRGBA(hex: h) ?? .white }

    /// The Plaza with doors to `games`, a cover on each door whose picture
    /// is in `covers` (by listing id), and a hello for `playerName`.
    public static func build(games: [GameListing], covers: [String: Data] = [:], playerName: String) -> Plaza {
        var environment = EnvironmentSettings.default
        environment.skyTop = hex("#3B8EEA")
        environment.skyBottom = hex("#BFE3FF")
        environment.skyStyle = .clouds
        environment.sunPitchDegrees = -52
        environment.sunYawDegrees = 40
        environment.ambientIntensity = 0.62
        environment.groundColor = hex("#4CAF50")
        environment.music = .calm

        var blocks: [BlockData] = []
        var images: [WorldImage] = []
        var doors: [UUID: Door] = [:]
        let white = ColorRGBA.white

        @discardableResult
        func add(_ name: String, _ shape: BlockShape = .box, at position: Vec3, size: Vec3, turn: Float = 0,
                 colour: ColorRGBA, material: MaterialKind = .plastic, collides: Bool = true,
                 behavior: BlockBehavior = .none) -> Int {
            let rotation = turn == 0 ? Quat.identity : Quat.euler(degrees: Vec3(0, turn, 0))
            blocks.append(BlockData(name: name, shape: shape, transform: Transform3D(position: position, rotation: rotation, scale: size),
                                    color: colour, material: material, hasCollision: collides, behavior: behavior))
            return blocks.count - 1
        }

        // The ground and the plaza.
        add("Meadow", .cylinder, at: Vec3(0, -0.6, 0), size: Vec3(130, 1, 130), colour: hex("#5DBB63"), material: .grass)
        blocks[blocks.count - 1].tags = ["ground"]
        add("Plaza", .cylinder, at: Vec3(0, -0.05, 0), size: Vec3(48, 0.2, 48), colour: hex("#E8E1D5"), material: .stone)
        add("Inner ring", .cylinder, at: Vec3(0, 0.02, 0), size: Vec3(20, 0.08, 20), colour: hex("#C9BFAE"), material: .stone)
        add("Spawn", .cylinder, at: Vec3(0, 0.08, 13), size: Vec3(2.6, 0.12, 2.6), colour: hex("#22D3EE"), material: .neon, behavior: .spawn)

        // The fountain, with the cube that says where you are.
        add("Fountain basin", .cylinder, at: Vec3(0, 0.45, 0), size: Vec3(7.5, 0.9, 7.5), colour: hex("#B8C4D6"), material: .stone)
        var water = hex("#4FC3F7")
        water.a = 0.8
        add("Fountain water", .cylinder, at: Vec3(0, 0.85, 0), size: Vec3(6.6, 0.15, 6.6), colour: water, material: .water, collides: false)
        add("Fountain column", .cylinder, at: Vec3(0, 2, 0), size: Vec3(1, 3, 1), colour: hex("#DDE6F2"), material: .stone)
        let cube = add("Ablox cube", at: Vec3(0, 4.6, 0), size: Vec3(1.8, 1.8, 1.8), colour: hex("#22D3EE"), material: .neon)
        blocks[cube].animation = BlockAnimation(kind: .spin, speed: 0.6)
        blocks[cube].light = BlockLight(kind: .point, color: hex("#7DE9FF"), intensity: 1.4, range: 12)
        blocks[cube].particles = .sparkles
        blocks[cube].label = BlockLabel(lines: [BlockLabel.Line(text: L("Ablox Plaza"), color: white),
                                                BlockLabel.Line(text: L("Welcome, {}!", playerName), color: hex("#FFE27A"))],
                                        height: 1.1, size: 1.25, range: 60)

        // Doors round the plaza, facing the fountain, with the side the player starts on left open.
        var entries: [(title: String, colour: String, door: Door, cover: Data?)] = games.enumerated().map { i, g in
            (g.title, doorColours[i % doorColours.count], .game(g.id), covers[g.id])
        }
        // Only real pictures, and no more than a world may carry.
        for i in entries.indices {
            if let cover = entries[i].cover, !WorldImage(name: "", data: cover).isAcceptable { entries[i].cover = nil }
            if i >= WorldImage.maximumCount { entries[i].cover = nil }
        }
        entries.append((L("My closet"), "#F472B6", .closet, nil))
        entries.append((L("All games"), "#4ADE80", .allGames, nil))
        let radius: Float = 17
        let span: Float = 290
        for (i, e) in entries.enumerated() {
            // 0° is straight ahead from the start (−Z); doors run from the left round to the right.
            let angle = -span / 2 + span * Float(i) / Float(max(1, entries.count - 1))
            let r = angle * .pi / 180
            let x = sin(r) * radius, z = -cos(r) * radius
            let colour = hex(e.colour)
            func local(_ dx: Float, _ dy: Float, _ dz: Float = 0) -> Vec3 {
                Vec3(x + cos(r) * dx - sin(r) * dz, dy, z + sin(r) * dx + cos(r) * dz)
            }
            add("Door step \(i)", .cylinder, at: local(0, 0.08, 1.4), size: Vec3(3.6, 0.12, 3.6), colour: colour, material: .neon)
            for side: Float in [-1, 1] {
                add("Door post \(i)", at: local(side * 2.6, 2.7), size: Vec3(0.7, 5.4, 0.7), turn: -angle, colour: hex("#F8FAFC"))
            }
            let top = add("Door top \(i)", at: local(0, 5.7), size: Vec3(6, 0.8, 0.9), turn: -angle, colour: colour)
            blocks[top].light = BlockLight(kind: .point, color: colour, intensity: 1.2, range: 9)
            var face = colour
            if e.cover == nil { face.a = 0.65 }
            let screen = add("Door \(i)", at: local(0, 2.6, -0.05), size: Vec3(4.5, 5, 0.2), turn: -angle, colour: face,
                             material: e.cover == nil ? .glass : .plastic, behavior: .trigger)
            blocks[screen].tags = ["door"]
            if let cover = e.cover {
                let picture = WorldImage(name: e.title, data: cover)
                images.append(picture)
                blocks[screen].imageID = picture.id
            }
            blocks[screen].label = BlockLabel(lines: [BlockLabel.Line(text: e.title, color: white)], height: 1.5, size: 1.3, range: 45)
            doors[blocks[screen].id] = e.door
        }

        // Trees and lamps round the edge, benches by the fountain, blocks floating for fun.
        for i in 0..<14 {
            let a = Float(i) / 14 * 2 * .pi + 0.2
            let r = 30 + Float(i % 3) * 3
            let x = sin(a) * r, z = cos(a) * r
            add("Tree trunk", .cylinder, at: Vec3(x, 1.4, z), size: Vec3(0.8, 2.8, 0.8), colour: hex("#8D5A3B"), material: .wood)
            add("Tree top", .sphere, at: Vec3(x, 3.8, z), size: Vec3(3.6, 3.4, 3.6), colour: i % 4 == 0 ? hex("#F9A8D4") : hex("#3FAE4C"), material: .grass)
        }
        for i in 0..<8 {
            let a = Float(i) / 8 * 2 * .pi + .pi / 8
            let x = sin(a) * 23, z = cos(a) * 23
            add("Lamp post", .cylinder, at: Vec3(x, 1.8, z), size: Vec3(0.25, 3.6, 0.25), colour: hex("#334155"), material: .metal)
            let lamp = add("Lamp", .sphere, at: Vec3(x, 3.8, z), size: Vec3(0.7, 0.7, 0.7), colour: hex("#FFF3C4"), material: .neon)
            blocks[lamp].light = BlockLight(kind: .point, color: hex("#FFE7A0"), intensity: 0.9, range: 8)
        }
        for a: Float in [60, 120, 240, 300] {
            let r = a * .pi / 180
            add("Bench", at: Vec3(sin(r) * 7.2, 0.45, cos(r) * 7.2), size: Vec3(2.6, 0.3, 0.9), turn: a, colour: hex("#B7794B"), material: .wood)
        }
        let floaters: [(Vec3, String)] = [(Vec3(-9, 6, -6), "#F472B6"), (Vec3(10, 7, -4), "#FFC93C"), (Vec3(-6, 8, 8), "#A855F7"), (Vec3(8, 6.5, 7), "#4ADE80")]
        for (at, c) in floaters {
            let f = add("Floating block", at: at, size: Vec3(1.2, 1.2, 1.2), colour: hex(c), material: .neon, collides: false)
            blocks[f].animation = BlockAnimation(kind: .bounce, speed: 0.8)
        }

        let hello = L("Walk into a door to visit a game.").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        let script = ScriptFile(name: "main.absc", source: "on join(p)\n  p.message(\"\(hello)\", 5)\nend\n")
        let world = WorldDocument(id: worldID, name: L("Ablox Plaza"), authorName: "Ablox", environment: environment,
                                  blocks: blocks, scripts: [script], images: images)
        return Plaza(world: world, doors: doors)
    }
}
