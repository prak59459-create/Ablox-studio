import Foundation

/// A world described in the simplest JSON that can describe one, so that an
/// assistant can write it and Studio can check it.
///
/// ## Why not just ask for a world file
///
/// A `WorldDocument` has UUIDs, nested transforms, quaternions and a rule
/// vocabulary. An assistant asked for one produces something that looks right
/// and is wrong in a way nobody can see until a block is inside the floor —
/// and the failure modes are all silent.
///
/// A plan is flat and small: a list of parts with positions and sizes, using
/// the same words the part palette uses. Everything in it can be checked
/// against something that already exists — `PresetKind`, `BlockShape`,
/// `BlockBehavior` — so a made-up value is caught by name rather than turning
/// into a default nobody asked for.
///
/// Studio expands the plan into a real world. The assistant never writes a
/// UUID, never writes a quaternion, and cannot produce a document that fails
/// to open.
///
/// ## Everything here is untrusted, in a different way
///
/// Text pasted from an assistant is not hostile, but it is unreliable in
/// specific ways: invented enum cases, numbers as strings, coordinates in the
/// thousands, a hundred thousand parts. Each of those is checked, and the
/// errors are phrased so they can be pasted straight back into the
/// conversation that produced them.
public struct MapPlan: Codable, Equatable, Sendable {

    public struct Part: Codable, Equatable, Sendable {
        /// A palette part name — `block`, `platform`, `spawn`, and so on.
        public var kind: String
        public var x: Float
        public var y: Float
        public var z: Float
        /// Size in metres. Omitted means the preset's own size.
        public var width: Float?
        public var height: Float?
        public var depth: Float?
        /// Rotation about the vertical axis, in degrees.
        public var yaw: Float?
        /// `#RRGGBB`. Omitted means the preset's own colour.
        public var color: String?
        /// A `BlockBehavior` name. Omitted means the preset's own behaviour.
        public var behavior: String?
        public var name: String?

        public init(
            kind: String,
            x: Float, y: Float, z: Float,
            width: Float? = nil, height: Float? = nil, depth: Float? = nil,
            yaw: Float? = nil, color: String? = nil,
            behavior: String? = nil, name: String? = nil
        ) {
            self.kind = kind
            self.x = x; self.y = y; self.z = z
            self.width = width; self.height = height; self.depth = depth
            self.yaw = yaw; self.color = color
            self.behavior = behavior; self.name = name
        }
    }

    public var name: String
    public var summary: String?
    public var parts: [Part]

    public init(name: String, summary: String? = nil, parts: [Part]) {
        self.name = name
        self.summary = summary
        self.parts = parts
    }

    // MARK: Limits

    public enum Limits {
        /// Enough for a substantial course, small enough that a runaway
        /// generator cannot fill the iPad's memory.
        public static let maximumParts = 600
        public static let maximumTextBytes = 512 * 1024
        /// Metres from the origin. The floor is 40 across; a part at 900 is a
        /// mistake, not a design.
        public static let maximumCoordinate: Float = 500
        public static let maximumSize: Float = 200
        public static let minimumSize: Float = 0.05
        public static let maximumNameLength = 60
    }
}

// MARK: - Problems

/// What was wrong with a plan, phrased to be handed back to whoever wrote it.
public struct MapPlanProblem: Error, Equatable, Sendable {
    /// Index into `parts`, when the problem is about one part.
    public let partIndex: Int?
    public let message: String

    public init(partIndex: Int? = nil, message: String) {
        self.partIndex = partIndex
        self.message = message
    }

    public var description: String {
        guard let partIndex else { return message }
        return L("Part {}: {}", partIndex + 1, message)
    }
}

public struct MapPlanResult: Equatable, Sendable {
    public let world: WorldDocument?
    public let problems: [MapPlanProblem]

    public var isUsable: Bool { world != nil }
}

// MARK: - Reading a plan

public extension MapPlan {

    /// Parses text pasted from an assistant.
    ///
    /// Tolerant of the two things assistants reliably add: a ```json fence,
    /// and a sentence before or after the JSON. Neither is worth making
    /// someone clean up by hand on an iPad keyboard.
    static func decode(from text: String) -> Result<MapPlan, MapPlanProblem> {
        guard text.utf8.count <= Limits.maximumTextBytes else {
            return .failure(MapPlanProblem(message: L("That is too much text to read.")))
        }

        let json = extractJSON(from: text)
        guard !json.isEmpty else {
            return .failure(MapPlanProblem(message: L("No JSON found. Paste the whole block, including the braces.")))
        }

        do {
            let plan = try JSONDecoder().decode(MapPlan.self, from: Data(json.utf8))
            return .success(plan)
        } catch let DecodingError.keyNotFound(key, _) {
            return .failure(MapPlanProblem(message: L("A part is missing “{}”.", key.stringValue)))
        } catch let DecodingError.typeMismatch(_, context) {
            let field = context.codingPath.last?.stringValue ?? "?"
            return .failure(MapPlanProblem(message: L("“{}” is the wrong type — numbers must not be in quotes.", field)))
        } catch {
            return .failure(MapPlanProblem(message: L("That JSON could not be read.")))
        }
    }

    /// Finds the JSON object inside surrounding prose or a code fence.
    ///
    /// Brace matching rather than a regex, because a nested object would end a
    /// regex-matched span at the first `}` and leave a truncated document that
    /// fails to parse for a reason nobody could act on.
    static func extractJSON(from text: String) -> String {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else { return "" }

        var depth = 0
        var inString = false
        var escaped = false

        for index in start..<characters.count {
            let character = characters[index]

            if escaped { escaped = false; continue }
            if character == "\\" && inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if inString { continue }

            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(characters[start...index]) }
            }
        }
        return ""
    }

    /// Turns a plan into a world, reporting everything wrong with it.
    ///
    /// All problems at once, not the first: someone pasting this back into a
    /// conversation should be able to fix it in one round rather than five.
    func build(named fallbackName: String = "AI World") -> MapPlanResult {
        var problems: [MapPlanProblem] = []

        guard !parts.isEmpty else {
            return MapPlanResult(world: nil, problems: [
                MapPlanProblem(message: L("The plan has no parts in it."))
            ])
        }
        guard parts.count <= Limits.maximumParts else {
            return MapPlanResult(world: nil, problems: [
                MapPlanProblem(message: L("The plan has {} parts. The limit is {}.", parts.count, Limits.maximumParts))
            ])
        }

        var world = WorldDocument(name: cleanedName(fallbackName))
        var built: [BlockData] = []

        for (index, part) in parts.enumerated() {
            switch block(from: part, index: index) {
            case let .success(block):
                built.append(block)
            case let .failure(problem):
                problems.append(problem)
            }
        }

        guard !built.isEmpty else {
            return MapPlanResult(world: nil, problems: problems)
        }

        // A world with no spawn point opens, but nobody can play it. Adding
        // one is friendlier than refusing the whole import over something the
        // assistant simply forgot — and it is said out loud, not silently.
        if !built.contains(where: { $0.behavior == .spawn }) {
            var spawn = BlockData.preset(.spawn, at: Vec3(0, 0.1, 0))
            spawn.name = L("Spawn")
            built.insert(spawn, at: 0)
            problems.append(MapPlanProblem(message: L("No spawn point was given, so one was added at the centre.")))
        }

        world.blocks = built
        return MapPlanResult(world: world, problems: problems)
    }

    private func cleanedName(_ fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(Limits.maximumNameLength))
    }

    private func block(from part: Part, index: Int) -> Result<BlockData, MapPlanProblem> {
        guard let kind = BlockData.PresetKind(rawValue: part.kind.lowercased()) else {
            return .failure(MapPlanProblem(
                partIndex: index,
                message: L("“{}” is not a part. Use one of: {}", part.kind, MapPlan.partVocabulary)
            ))
        }

        for (label, value) in [("x", part.x), ("y", part.y), ("z", part.z)] {
            guard value.isFinite, abs(value) <= Limits.maximumCoordinate else {
                return .failure(MapPlanProblem(
                    partIndex: index,
                    message: L("{} is {}, which is off the map. Keep coordinates within ±{}.",
                               label, value, Limits.maximumCoordinate)
                ))
            }
        }

        var block = BlockData.preset(kind, at: Vec3(part.x, part.y, part.z))

        // Size: each axis independently, so giving only a height is fine.
        var scale = block.scale
        for (axis, requested) in [(0, part.width), (1, part.height), (2, part.depth)] {
            guard let requested else { continue }
            guard requested.isFinite, requested >= Limits.minimumSize, requested <= Limits.maximumSize else {
                return .failure(MapPlanProblem(
                    partIndex: index,
                    message: L("A size of {} is not usable. Sizes run from {} to {}.",
                               requested, Limits.minimumSize, Limits.maximumSize)
                ))
            }
            switch axis {
            case 0: scale.x = requested
            case 1: scale.y = requested
            default: scale.z = requested
            }
        }
        block.scale = scale

        if let yaw = part.yaw {
            guard yaw.isFinite else {
                return .failure(MapPlanProblem(partIndex: index, message: L("The rotation is not a number.")))
            }
            block.transform.rotation = Quat.euler(degrees: Vec3(0, yaw, 0))
        }

        if let hex = part.color {
            guard let colour = ColorRGBA(hex: hex) else {
                return .failure(MapPlanProblem(
                    partIndex: index,
                    message: L("“{}” is not a colour. Use #RRGGBB.", hex)
                ))
            }
            block.color = colour
        }

        if let name = part.behavior {
            guard let behavior = BlockBehavior(rawValue: name.lowercased()) else {
                return .failure(MapPlanProblem(
                    partIndex: index,
                    message: L("“{}” is not a behaviour. Use one of: {}", name, MapPlan.behaviourVocabulary)
                ))
            }
            block.behavior = behavior
        }

        if let name = part.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { block.name = String(trimmed.prefix(Limits.maximumNameLength)) }
        }

        return .success(block)
    }
}

// MARK: - Vocabulary

public extension MapPlan {

    /// The part names an assistant may use, from the palette itself.
    ///
    /// Read from `allCases` rather than written out, so the prompt can never
    /// offer something the palette does not have — and adding a part to the
    /// palette updates the prompt with no separate edit.
    static var partVocabulary: String {
        BlockData.PresetKind.allCases.map(\.rawValue).joined(separator: ", ")
    }

    static var behaviourVocabulary: String {
        BlockBehavior.allCases.map(\.rawValue).joined(separator: ", ")
    }
}
