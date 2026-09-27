import Foundation

// Ready-made things to build with: parts that are really several blocks (a
// house, a tree, a car) and whole starting worlds for the common kinds of
// game (an obby, a race, a battle, a tycoon), each already playable.

// MARK: - The part library

/// Several blocks that go together, placed as one: the base's middle at
/// the origin.
public struct Prefab: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var blocks: [BlockData]
    /// Made by the player (Studio → Library → Save), not built in.
    public var isCustom: Bool

    public init(id: UUID = UUID(), name: String, symbolName: String = "cube.fill", blocks: [BlockData], isCustom: Bool = false) {
        self.id = id
        self.name = String(name.prefix(40))
        self.symbolName = symbolName
        self.blocks = blocks
        self.isCustom = isCustom
    }
}

public enum PrefabLibrary {

    private static func hex(_ value: String) -> ColorRGBA { ColorRGBA(hex: value) ?? .defaultBlock }

    private static func part(_ name: String, _ shape: BlockShape = .box, at position: Vec3, size: Vec3, _ color: String,
                             _ material: MaterialKind = .plastic, rotation: Vec3 = .zero) -> BlockData {
        var block = BlockData(name: name, shape: shape, transform: Transform3D(position: position, scale: size),
                              color: hex(color), material: material)
        if rotation != .zero { block.rotationDegrees = rotation }
        return block
    }

    /// The parts every Studio has.
    public static var builtIn: [Prefab] {
        [house, tree, pine, car, lampPost, fence, bench, table, rock, bush, tower, stairs, bridge, coinRing]
            .map { Prefab(id: stableID($0.name), name: L($0.name), symbolName: $0.symbol, blocks: $0.blocks) }
    }

    private static func stableID(_ name: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in name.utf8.enumerated() { bytes[index % 16] ^= byte &+ UInt8(truncatingIfNeeded: index * 31) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private typealias Entry = (name: String, symbol: String, blocks: [BlockData])

    private static var house: Entry {
        ("House", "house.fill", [
            part("Floor", at: Vec3(0, 0.1, 0), size: Vec3(6, 0.2, 6), "#A8A29E", .wood),
            part("Back wall", at: Vec3(0, 1.6, -2.9), size: Vec3(6, 3, 0.2), "#FDE68A", .brick),
            part("Left wall", at: Vec3(-2.9, 1.6, 0), size: Vec3(0.2, 3, 6), "#FDE68A", .brick),
            part("Right wall", at: Vec3(2.9, 1.6, 0), size: Vec3(0.2, 3, 6), "#FDE68A", .brick),
            part("Front left", at: Vec3(-1.9, 1.6, 2.9), size: Vec3(2.2, 3, 0.2), "#FDE68A", .brick),
            part("Front right", at: Vec3(1.9, 1.6, 2.9), size: Vec3(2.2, 3, 0.2), "#FDE68A", .brick),
            part("Over the door", at: Vec3(0, 2.7, 2.9), size: Vec3(1.6, 0.8, 0.2), "#FDE68A", .brick),
            part("Roof", .cone, at: Vec3(0, 4.3, 0), size: Vec3(8, 2.4, 8), "#B91C1C", .matte)
        ])
    }

    private static var tree: Entry {
        ("Tree", "tree.fill", [
            part("Trunk", .cylinder, at: Vec3(0, 1.5, 0), size: Vec3(0.6, 3, 0.6), "#92400E", .wood),
            part("Leaves", .sphere, at: Vec3(0, 3.8, 0), size: Vec3(3, 2.6, 3), "#16A34A", .grass)
        ])
    }

    private static var pine: Entry {
        ("Pine tree", "tree", [
            part("Trunk", .cylinder, at: Vec3(0, 0.8, 0), size: Vec3(0.5, 1.6, 0.5), "#78350F", .wood),
            part("Lower branches", .cone, at: Vec3(0, 2.4, 0), size: Vec3(3, 2.4, 3), "#15803D", .grass),
            part("Upper branches", .cone, at: Vec3(0, 3.9, 0), size: Vec3(2, 2, 2), "#166534", .grass)
        ])
    }

    private static var car: Entry {
        var body = part("Car", at: Vec3(0, 0.8, 0), size: Vec3(2, 0.8, 4), "#EF4444", .metal)
        body.behavior = .vehicle
        body.gimmick.vehicle = "car"
        return ("Car", "car.fill", [
            body,
            part("Cabin", at: Vec3(0, 1.5, -0.3), size: Vec3(1.8, 0.7, 2), "#BAE6FD", .glass),
            part("Wheel", .cylinder, at: Vec3(-1.05, 0.4, 1.3), size: Vec3(0.8, 0.3, 0.8), "#111827", .matte, rotation: Vec3(0, 0, 90)),
            part("Wheel", .cylinder, at: Vec3(1.05, 0.4, 1.3), size: Vec3(0.8, 0.3, 0.8), "#111827", .matte, rotation: Vec3(0, 0, 90)),
            part("Wheel", .cylinder, at: Vec3(-1.05, 0.4, -1.3), size: Vec3(0.8, 0.3, 0.8), "#111827", .matte, rotation: Vec3(0, 0, 90)),
            part("Wheel", .cylinder, at: Vec3(1.05, 0.4, -1.3), size: Vec3(0.8, 0.3, 0.8), "#111827", .matte, rotation: Vec3(0, 0, 90))
        ])
    }

    private static var lampPost: Entry {
        var lamp = part("Lamp", .sphere, at: Vec3(0, 3.6, 0), size: Vec3(0.6, 0.6, 0.6), "#FEF3C7", .neon)
        lamp.light = BlockLight(kind: .point, intensity: 0.7, range: 12)
        return ("Lamp post", "lightbulb.fill", [
            part("Post", .cylinder, at: Vec3(0, 1.7, 0), size: Vec3(0.2, 3.4, 0.2), "#374151", .metal),
            lamp
        ])
    }

    private static var fence: Entry {
        var blocks: [BlockData] = []
        for index in 0..<5 {
            blocks.append(part("Post", at: Vec3(Float(index) * 1.5 - 3, 0.6, 0), size: Vec3(0.2, 1.2, 0.2), "#FEF3C7", .wood))
        }
        blocks.append(part("Rail", at: Vec3(0, 0.9, 0), size: Vec3(6.2, 0.15, 0.1), "#FEF3C7", .wood))
        blocks.append(part("Rail", at: Vec3(0, 0.45, 0), size: Vec3(6.2, 0.15, 0.1), "#FEF3C7", .wood))
        return ("Fence", "square.split.1x2", blocks)
    }

    private static var bench: Entry {
        ("Bench", "chair.lounge.fill", [
            part("Seat", at: Vec3(0, 0.5, 0), size: Vec3(2, 0.15, 0.6), "#B45309", .wood),
            part("Back", at: Vec3(0, 0.9, -0.25), size: Vec3(2, 0.6, 0.1), "#B45309", .wood),
            part("Leg", at: Vec3(-0.85, 0.22, 0), size: Vec3(0.12, 0.45, 0.5), "#374151", .metal),
            part("Leg", at: Vec3(0.85, 0.22, 0), size: Vec3(0.12, 0.45, 0.5), "#374151", .metal)
        ])
    }

    private static var table: Entry {
        var blocks = [part("Top", at: Vec3(0, 1, 0), size: Vec3(2, 0.12, 1.2), "#D97706", .wood)]
        for (x, z) in [(-0.85, -0.5), (0.85, -0.5), (-0.85, 0.5), (0.85, 0.5)] as [(Float, Float)] {
            blocks.append(part("Leg", at: Vec3(x, 0.47, z), size: Vec3(0.1, 0.94, 0.1), "#92400E", .wood))
        }
        return ("Table", "table.furniture.fill", blocks)
    }

    private static var rock: Entry {
        ("Rock", "circle.hexagongrid.fill", [
            part("Rock", .sphere, at: Vec3(0, 0.6, 0), size: Vec3(2, 1.3, 1.6), "#78716C", .stone),
            part("Pebble", .sphere, at: Vec3(1, 0.3, 0.6), size: Vec3(0.7, 0.5, 0.6), "#A8A29E", .stone)
        ])
    }

    private static var bush: Entry {
        ("Bush", "leaf.fill", [
            part("Bush", .sphere, at: Vec3(0, 0.5, 0), size: Vec3(1.6, 1, 1.4), "#22C55E", .grass),
            part("Bush", .sphere, at: Vec3(0.7, 0.4, 0.3), size: Vec3(1, 0.8, 1), "#16A34A", .grass)
        ])
    }

    private static var tower: Entry {
        ("Tower", "building.columns.fill", [
            part("Tower", .cylinder, at: Vec3(0, 4, 0), size: Vec3(3, 8, 3), "#D6D3D1", .stone),
            part("Top", .cylinder, at: Vec3(0, 8.3, 0), size: Vec3(3.6, 0.6, 3.6), "#A8A29E", .stone),
            part("Roof", .cone, at: Vec3(0, 9.8, 0), size: Vec3(3.6, 2.4, 3.6), "#1D4ED8", .matte)
        ])
    }

    private static var stairs: Entry {
        var blocks: [BlockData] = []
        for step in 0..<6 {
            let height = Float(step + 1) * 0.5
            blocks.append(part("Step", at: Vec3(0, height / 2, -Float(step) * 0.8), size: Vec3(2.4, height, 0.8), "#94A3B8", .stone))
        }
        return ("Stairs", "stairs", blocks)
    }

    private static var bridge: Entry {
        var blocks = [part("Deck", at: Vec3(0, 2, 0), size: Vec3(3, 0.3, 10), "#A16207", .wood)]
        for z in [-4.5, 4.5] as [Float] {
            for x in [-1.4, 1.4] as [Float] {
                blocks.append(part("Pillar", .cylinder, at: Vec3(x, 1, z), size: Vec3(0.4, 2, 0.4), "#57534E", .stone))
            }
        }
        blocks.append(part("Rail", at: Vec3(-1.45, 2.6, 0), size: Vec3(0.1, 0.6, 10), "#A16207", .wood))
        blocks.append(part("Rail", at: Vec3(1.45, 2.6, 0), size: Vec3(0.1, 0.6, 10), "#A16207", .wood))
        return ("Bridge", "road.lanes", blocks)
    }

    private static var coinRing: Entry {
        var blocks: [BlockData] = []
        for index in 0..<8 {
            let angle = Float(index) / 8 * 2 * .pi
            var coin = part("Coin", .cylinder, at: Vec3(cos(angle) * 3, 1, sin(angle) * 3), size: Vec3(0.8, 0.15, 0.8),
                            "#FACC15", .metal, rotation: Vec3(90, 0, 0))
            coin.behavior = .collectible
            coin.scoreValue = 10
            coin.hasCollision = false
            coin.tags = ["coin"]
            blocks.append(coin)
        }
        return ("Coin ring", "circle.circle.fill", blocks)
    }
}

// MARK: - Starting worlds

public enum WorldTemplates {

    private static func ground(_ world: inout WorldDocument, size: Float = 60, color: String = "#37474F") {
        world.blocks.append(BlockData(name: "Floor", shape: .box,
                                      transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(size, 1, size)),
                                      color: ColorRGBA(hex: color)!, material: .matte, tags: ["ground"]))
    }

    private static func block(_ name: String, at position: Vec3, size: Vec3, _ color: String, _ material: MaterialKind = .plastic,
                              behavior: BlockBehavior = .none) -> BlockData {
        BlockData(name: name, shape: .box, transform: Transform3D(position: position, scale: size),
                  color: ColorRGBA(hex: color)!, material: material, behavior: behavior)
    }

    /// An obstacle course over lava, with numbered checkpoints, a timer and
    /// a best-times board.
    public static func obby(named name: String, author: String = "") -> WorldDocument {
        var world = WorldDocument(name: name, authorName: author)
        world.environment.skyStyle = .clouds
        world.environment.music = .adventure
        world.blocks.append(block("Lava", at: Vec3(0, -0.5, -30), size: Vec3(40, 1, 90), "#EF4444", .neon, behavior: .hazard))
        world.blocks.append(block("Start", at: Vec3(0, 0.25, 8), size: Vec3(8, 0.5, 8), "#22D3EE"))
        world.blocks.append(BlockData.preset(.spawn, at: Vec3(0, 0.6, 8)))
        var z: Float = 2
        var stage = 1
        for index in 0..<14 {
            z -= 4.5
            let x: Float = [0, 3, -3, 2, -2][index % 5]
            let height = Float(index) * 0.4 + 0.5
            var step = block("Jump \(index + 1)", at: Vec3(x, height, z), size: Vec3(3, 0.5, 3),
                             ["#A855F7", "#22D3EE", "#F59E0B"][index % 3])
            if index % 5 == 4 {
                step.behavior = .checkpoint
                step.gimmick.stage = stage
                step.name = "Checkpoint \(stage)"
                step.color = ColorRGBA(hex: "#4ADE80")!
                stage += 1
            }
            if index == 7 {
                step.behavior = .elevator
                step.gimmick.moveOffset = Vec3(4, 0, 0)
                step.gimmick.moveSeconds = 2.5
            }
            world.blocks.append(step)
        }
        world.blocks.append(block("Finish", at: Vec3(0, 6.5, z - 5), size: Vec3(6, 0.5, 6), "#FACC15", .neon, behavior: .goal))
        world.scripts = [ScriptFile(name: "obby", source: """
        -- A timer for everyone, and the fastest times kept.
        on join(p)
          p.started = game.time
          p.ui_text("timer", "0.0 s", {at: "top", size: 26, bold: true})
          p.waypoint(block("Finish"), "Finish")
        end

        on tick(dt)
          for p in players() do
            if p.started then
              p.ui_text("timer", fixed(game.time - p.started, 1) + " s")
            end
          end
        end

        on touch(p, b)
          if b.name == "Finish" and p.started then
            let time = game.time - p.started
            p.started = nil
            let place = leaderboard("Fastest", p, time, {lower: true})
            p.message("Finished in " + fixed(time, 1) + " s!", 3)
            particles("confetti", p, {amount: 80})
            p.show_leaderboard("Fastest")
          end
        end
        """)]
        return world
    }

    /// A lap round a ring road in cars, with checkpoints and a countdown.
    public static func race(named name: String, author: String = "") -> WorldDocument {
        var world = WorldDocument(name: name, authorName: author)
        world.environment.skyStyle = .sunset
        world.environment.music = .race
        ground(&world, size: 120, color: "#65A30D")
        for index in 0..<24 {
            let angle = Float(index) / 24 * 2 * .pi
            var road = block("Road", at: Vec3(cos(angle) * 30, 0.05, sin(angle) * 30), size: Vec3(8, 0.1, 8.5), "#374151", .matte)
            road.rotationDegrees = Vec3(0, -angle * 180 / .pi, 0)
            if index % 6 == 3 {
                road.behavior = .checkpoint
                road.gimmick.stage = index / 6 + 1
                road.name = "Checkpoint \(index / 6 + 1)"
            }
            world.blocks.append(road)
        }
        world.blocks.append(block("Finish line", at: Vec3(30, 0.12, 0), size: Vec3(8, 0.1, 1), "#F5F5F5", .neon, behavior: .trigger))
        for lane in 0..<4 {
            var car = block("Car \(lane + 1)", at: Vec3(26 + Float(lane) * 2.6, 0.6, 6), size: Vec3(2, 0.8, 3.6), "#EF4444", .metal,
                            behavior: .vehicle)
            car.color = ColorRGBA(hex: ["#EF4444", "#3B82F6", "#FACC15", "#22C55E"][lane])!
            car.gimmick.vehicle = "kart"
            car.gimmick.vehicleSpeed = 2.5
            world.blocks.append(car)
            world.blocks.append(BlockData.preset(.spawn, at: Vec3(26 + Float(lane) * 2.6, 0.2, 10)))
        }
        world.scripts = [ScriptFile(name: "race", source: """
        -- Get in a car, go round once, and cross the line.
        on start()
          countdown(5, "Get in a car!")
        end

        on countdown(label, p)
          if label == "Get in a car!" then
            announce("Go!", 2)
            sound("bell")
            for q in players() do q.lap_start = game.time end
          end
        end

        on touch(p, b)
          if b.name == "Finish line" and p.lap_start and game.time - p.lap_start > 10 then
            let lap = game.time - p.lap_start
            p.lap_start = game.time
            leaderboard("Best lap", p, lap, {lower: true})
            p.message("Lap: " + fixed(lap, 2) + " s", 3)
            show_leaderboard("Best lap")
          end
        end
        """)]
        return world
    }

    /// Two teams, blasters and a score to reach.
    public static func battle(named name: String, author: String = "") -> WorldDocument {
        var world = WorldDocument(name: name, authorName: author)
        world.environment.skyStyle = .stars
        world.environment.timeOfDay = 20
        world.environment.music = .boss
        ground(&world, size: 60, color: "#1F2937")
        for (index, side) in ([-1, 1] as [Float]).enumerated() {
            var spawn = BlockData.preset(.spawn, at: Vec3(0, 0.2, side * 24))
            spawn.name = index == 0 ? "Red base" : "Blue base"
            spawn.color = ColorRGBA(hex: index == 0 ? "#EF4444" : "#3B82F6")!
            world.blocks.append(spawn)
            world.blocks.append(block("Wall", at: Vec3(side * 29.5, 2, 0), size: Vec3(1, 4, 60), "#4B5563", .stone))
            world.blocks.append(block("Wall", at: Vec3(0, 2, side * 29.5), size: Vec3(60, 4, 1), "#4B5563", .stone))
        }
        for (x, z) in [(-8, -6), (8, 6), (-10, 8), (10, -8), (0, 0)] as [(Float, Float)] {
            world.blocks.append(block("Cover", at: Vec3(x, 1, z), size: Vec3(4, 2, 1.2), "#9CA3AF", .brick))
        }
        var lamp = BlockData(name: "Lamp", shape: .sphere, transform: Transform3D(position: Vec3(0, 6, 0), scale: Vec3(1, 1, 1)),
                             color: ColorRGBA(hex: "#FEF3C7")!, material: .neon)
        lamp.light = BlockLight(kind: .point, intensity: 0.9, range: 30)
        world.blocks.append(lamp)
        world.scripts = [ScriptFile(name: "battle", source: """
        -- Red against blue; the first team to 10 wins.
        let goal = 10
        let red = 0
        let blue = 0

        on start()
          game.respawn_time = 3
          ui_text("score", "Red 0 : 0 Blue", {at: "top", size: 26, bold: true})
        end

        on join(p)
          if len(filter(players(), func(q) return q.team == "red" end)) <= len(filter(players(), func(q) return q.team == "blue" end)) then
            p.team = "red"
            p.teleport(block("Red base"))
          else
            p.team = "blue"
            p.teleport(block("Blue base"))
          end
          p.give("blaster")
        end

        on respawn(p)
          p.teleport(block(p.team == "red" and "Red base" or "Blue base"))
        end

        on death(victim, killer)
          if killer then
            if killer.team == "red" then red = red + 1 else blue = blue + 1 end
            killer.score = killer.score + 1
            ui_text("score", "Red " + red + " : " + blue + " Blue")
            if red >= goal then end_round("Red wins!") end
            if blue >= goal then end_round("Blue wins!") end
          end
        end
        """)]
        return world
    }

    /// Earn coins, buy droppers, get richer: a small tycoon.
    public static func tycoon(named name: String, author: String = "") -> WorldDocument {
        var world = WorldDocument(name: name, authorName: author)
        world.environment.skyStyle = .clouds
        world.environment.music = .shop
        ground(&world, size: 50, color: "#4D7C0F")
        world.blocks.append(BlockData.preset(.spawn, at: Vec3(0, 0.2, 10)))
        world.blocks.append(block("Plot", at: Vec3(0, 0.05, -4), size: Vec3(16, 0.1, 12), "#A8A29E", .stone))
        let pads: [(String, Float, String)] = [("Buy Dropper", -5, "#22C55E"), ("Buy Conveyor", 0, "#3B82F6"), ("Buy Factory", 5, "#A855F7")]
        for (name, x, color) in pads {
            world.blocks.append(block(name, at: Vec3(x, 0.15, 4), size: Vec3(2.4, 0.3, 2.4), color, .neon, behavior: .trigger))
        }
        world.scripts = [ScriptFile(name: "tycoon", source: """
        -- Coins every second; pads that make more. Progress is kept.
        let prices = {"Buy Dropper": 10, "Buy Conveyor": 60, "Buy Factory": 300}
        let gains = {"Buy Dropper": 1, "Buy Conveyor": 5, "Buy Factory": 25}

        on join(p)
          p.coins = 0
          p.income = 1
          p.ui_text("coins", "Coins: 0", {at: "top_left", size: 24, bold: true})
        end

        on loaded(p)
          p.coins = p.saved.coins or 0
          p.income = p.saved.income or 1
        end

        on start()
          every(1, func()
            for p in players() do
              p.coins = p.coins + p.income
              p.ui_text("coins", "Coins: " + p.coins + "  (+" + p.income + "/s)")
              p.save("coins", p.coins)
            end
          end)
        end

        on touch(p, b)
          let price = prices[b.name]
          if price then
            if p.coins >= price then
              p.coins = p.coins - price
              p.income = p.income + gains[b.name]
              p.save("income", p.income)
              sound("coin")
              particles("sparkles", b, {amount: 40})
              leaderboard("Richest", p, p.income)
            else
              p.message("You need " + price + " coins.", 2)
            end
          end
        end
        """)]
        return world
    }
}
