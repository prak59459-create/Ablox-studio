import Foundation

// MARK: - PeerID

/// Stable identity for one device in a session.
///
/// A thin wrapper over `UUID` rather than a bare `UUID` so that a peer id can
/// never be silently confused with a block id — both are UUIDs, and they show
/// up side by side in packet payloads.
public struct PeerID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    /// The 16 raw bytes, as they appear in a packet header.
    public var bytes: [UInt8] {
        let u = raw.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    /// Rebuilds a peer id from exactly 16 bytes. Returns nil otherwise.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        raw = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public var description: String { String(raw.uuidString.prefix(8)) }

    /// FNV-1a over all sixteen id bytes, salted with `seed`.
    ///
    /// Stable across processes, platforms and launches — unlike `hashValue`,
    /// which Swift seeds randomly per process. Used wherever a peer id needs
    /// to pick deterministically from a list (avatar looks, colour slots) and
    /// every device must reach the same answer.
    public func stableHash(seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 &+ seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Sentinel used by the host when a message is server-authored rather
    /// than relayed from a player.
    public static let host = PeerID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
}

// MARK: - AvatarProfile

/// How a player looks and what they are called. Small enough to ride along in
/// the handshake, so joining players appear correctly on the first frame.
public struct AvatarProfile: Codable, Hashable, Sendable {
    public var displayName: String
    public var bodyColor: ColorRGBA
    public var headColor: ColorRGBA
    public var accentColor: ColorRGBA
    public var hat: HatStyle
    public var height: Float
    /// What they are riding, drawn around them: a car, a bike, a jetpack…
    /// Set by a game's script; purely how they look — speed is separate.
    public var ride: Ride
    public var rideColor: ColorRGBA
    /// A few words under their name — a badge they earned, "Builder".
    public var title: String
    /// Eyes and mouth.
    public var face: Face
    /// The hat's own colour; nil wears the legs' colour, as before.
    public var hatColor: ColorRGBA?
    /// A small friend that follows them about.
    public var pet: Pet
    public var petColor: ColorRGBA
    /// Something left behind while moving: sparkles, bubbles…
    public var trail: Trail
    /// A glowing ring round the feet.
    public var aura: Aura

    public init(
        displayName: String = "Player",
        bodyColor: ColorRGBA = ColorRGBA(hex: "#22D3EE")!,
        headColor: ColorRGBA = ColorRGBA(hex: "#FFD60A")!,
        accentColor: ColorRGBA = ColorRGBA(hex: "#A855F7")!,
        hat: HatStyle = .none,
        height: Float = 1.0,
        ride: Ride = .none,
        rideColor: ColorRGBA = ColorRGBA(hex: "#EF4444")!,
        title: String = "",
        face: Face = .smile,
        hatColor: ColorRGBA? = nil,
        pet: Pet = .none,
        petColor: ColorRGBA = ColorRGBA(hex: "#F59E0B")!,
        trail: Trail = .none,
        aura: Aura = .none
    ) {
        self.displayName = displayName
        self.bodyColor = bodyColor
        self.headColor = headColor
        self.accentColor = accentColor
        self.hat = hat
        self.height = height
        self.ride = ride
        self.rideColor = rideColor
        self.title = title
        self.face = face
        self.hatColor = hatColor
        self.pet = pet
        self.petColor = petColor
        self.trail = trail
        self.aura = aura
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, bodyColor, headColor, accentColor, hat, height, ride, rideColor, title, face, hatColor, pet, petColor
        case hatNew, faceNew, petNew, trail, aura
    }

    // Written by hand so a profile saved before rides existed — on this
    // iPad, or arriving from one that has not updated — still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        bodyColor = try c.decode(ColorRGBA.self, forKey: .bodyColor)
        headColor = try c.decode(ColorRGBA.self, forKey: .headColor)
        accentColor = try c.decode(ColorRGBA.self, forKey: .accentColor)
        hat = (try? c.decodeIfPresent(HatStyle.self, forKey: .hatNew)) ?? (try? c.decode(HatStyle.self, forKey: .hat)) ?? HatStyle.none
        height = try c.decode(Float.self, forKey: .height)
        ride = (try? c.decodeIfPresent(Ride.self, forKey: .ride)) ?? Ride.none
        rideColor = (try? c.decodeIfPresent(ColorRGBA.self, forKey: .rideColor)) ?? ColorRGBA(hex: "#EF4444")!
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        face = (try? c.decodeIfPresent(Face.self, forKey: .faceNew)) ?? (try? c.decodeIfPresent(Face.self, forKey: .face)) ?? .smile
        hatColor = try? c.decodeIfPresent(ColorRGBA.self, forKey: .hatColor)
        pet = (try? c.decodeIfPresent(Pet.self, forKey: .petNew)) ?? (try? c.decodeIfPresent(Pet.self, forKey: .pet)) ?? Pet.none
        trail = (try? c.decodeIfPresent(Trail.self, forKey: .trail)) ?? Trail.none
        aura = (try? c.decodeIfPresent(Aura.self, forKey: .aura)) ?? Aura.none
        petColor = (try? c.decodeIfPresent(ColorRGBA.self, forKey: .petColor)) ?? ColorRGBA(hex: "#F59E0B")!
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(bodyColor, forKey: .bodyColor)
        try c.encode(headColor, forKey: .headColor)
        try c.encode(accentColor, forKey: .accentColor)
        if HatStyle.legacy.contains(hat) {
            try c.encode(hat, forKey: .hat)
        } else {
            try c.encode(HatStyle.none, forKey: .hat)
            try c.encode(hat, forKey: .hatNew)
        }
        try c.encode(height, forKey: .height)
        try c.encode(ride, forKey: .ride)
        try c.encode(rideColor, forKey: .rideColor)
        if !title.isEmpty { try c.encode(title, forKey: .title) }
        // Left out at their defaults, so an older iPad reads the profile as it
        // always did.
        // Newer hats, faces and pets go under keys of their own; the old
        // keys keep something every version knows, so an iPad that has not
        // updated reads the profile (and sees no hat) instead of failing.
        if Face.legacy.contains(face) {
            if face != .smile { try c.encode(face, forKey: .face) }
        } else {
            try c.encode(face, forKey: .faceNew)
        }
        try c.encodeIfPresent(hatColor, forKey: .hatColor)
        if pet != .none {
            if Pet.legacy.contains(pet) { try c.encode(pet, forKey: .pet) } else { try c.encode(pet, forKey: .petNew) }
            try c.encode(petColor, forKey: .petColor)
        }
        // Keys an older iPad does not know, and skips.
        if trail != .none { try c.encode(trail, forKey: .trail) }
        if aura != .none { try c.encode(aura, forKey: .aura) }
    }

    /// Left behind while moving.
    public enum Trail: String, Codable, CaseIterable, Sendable {
        case none, sparkle, fire, bubbles, hearts, stars, rainbow, snow, leaves, smoke, confetti, magic, sand

        public var displayName: String {
            switch self {
            case .none: return L("None")
            case .sparkle: return L("Sparkle trail")
            case .fire: return L("Fire trail")
            case .bubbles: return L("Bubble trail")
            case .hearts: return L("Heart trail")
            case .stars: return L("Star trail")
            case .rainbow: return L("Rainbow trail")
            case .snow: return L("Snow trail")
            case .leaves: return L("Leaf trail")
            case .smoke: return L("Smoke trail")
            case .confetti: return L("Confetti trail")
            case .magic: return L("Magic trail")
            case .sand: return L("Sand trail")
            }
        }

        /// The English name, kept as the original for the shop.
        public var englishName: String {
            switch self {
            case .none: return "None"
            case .sparkle: return "Sparkle trail"
            case .fire: return "Fire trail"
            case .bubbles: return "Bubble trail"
            case .hearts: return "Heart trail"
            case .stars: return "Star trail"
            case .rainbow: return "Rainbow trail"
            case .snow: return "Snow trail"
            case .leaves: return "Leaf trail"
            case .smoke: return "Smoke trail"
            case .confetti: return "Confetti trail"
            case .magic: return "Magic trail"
            case .sand: return "Sand trail"
            }
        }

        public var symbolName: String {
            switch self {
            case .none: return "nosign"
            case .sparkle: return "sparkle"
            case .fire: return "flame.fill"
            case .bubbles: return "bubbles.and.sparkles.fill"
            case .hearts: return "heart.fill"
            case .stars: return "star.fill"
            case .rainbow: return "rainbow"
            case .snow: return "snowflake"
            case .leaves: return "leaf.fill"
            case .smoke: return "smoke.fill"
            case .confetti: return "party.popper.fill"
            case .magic: return "wand.and.stars"
            case .sand: return "wind"
            }
        }

        /// The particles it is made of.
        public var particles: ParticleKind? {
            switch self {
            case .none: return nil
            case .sparkle: return .sparkles
            case .fire: return .fire
            case .bubbles: return .bubbles
            case .hearts: return .hearts
            case .stars: return .stars
            case .rainbow, .confetti: return .confetti
            case .snow: return .snow
            case .leaves: return .leaves
            case .smoke: return .smoke
            case .magic: return .magic
            case .sand: return .dust
            }
        }

        /// The rainbow runs through the colours in order; the rest use their
        /// particles' own.
        public func color(at time: Double) -> ColorRGBA? {
            guard self == .rainbow else { return nil }
            let colours = ColorRGBA.rainbow
            return colours[Int((time * 6).rounded(.down)) % colours.count]
        }

        public var price: Int {
            switch self {
            case .none: return 0
            case .sand, .smoke, .leaves: return 150
            case .bubbles, .snow, .confetti: return 200
            case .sparkle, .hearts, .stars: return 250
            case .fire, .magic: return 350
            case .rainbow: return 500
            }
        }
    }

    /// A glowing ring round the feet.
    public enum Aura: String, Codable, CaseIterable, Sendable {
        case none, gold, rainbow, fire, ice, shadow, electric, nature, galaxy

        public var displayName: String {
            switch self {
            case .none: return L("None")
            case .gold: return L("Gold aura")
            case .rainbow: return L("Rainbow aura")
            case .fire: return L("Fire aura")
            case .ice: return L("Ice aura")
            case .shadow: return L("Shadow aura")
            case .electric: return L("Electric aura")
            case .nature: return L("Nature aura")
            case .galaxy: return L("Galaxy aura")
            }
        }

        public var englishName: String {
            rawValue == "none" ? "None" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() + " aura"
        }

        public var symbolName: String {
            switch self {
            case .none: return "nosign"
            case .gold: return "sun.max.fill"
            case .rainbow: return "rainbow"
            case .fire: return "flame.circle.fill"
            case .ice: return "snowflake.circle.fill"
            case .shadow: return "moon.circle.fill"
            case .electric: return "bolt.circle.fill"
            case .nature: return "leaf.circle.fill"
            case .galaxy: return "sparkles"
            }
        }

        /// The ring's colours: one, or several it turns through.
        public var colors: [ColorRGBA] {
            switch self {
            case .none: return []
            case .gold: return [ColorRGBA(hex: "#FACC15")!, ColorRGBA(hex: "#FDE68A")!]
            case .rainbow: return ColorRGBA.rainbow
            case .fire: return [ColorRGBA(hex: "#F97316")!, ColorRGBA(hex: "#EF4444")!, ColorRGBA(hex: "#FACC15")!]
            case .ice: return [ColorRGBA(hex: "#7DD3FC")!, ColorRGBA(hex: "#E0F2FE")!]
            case .shadow: return [ColorRGBA(hex: "#4C1D95")!, ColorRGBA(hex: "#1E1B4B")!]
            case .electric: return [ColorRGBA(hex: "#22D3EE")!, ColorRGBA(hex: "#FDE047")!]
            case .nature: return [ColorRGBA(hex: "#4ADE80")!, ColorRGBA(hex: "#A3E635")!]
            case .galaxy: return [ColorRGBA(hex: "#A855F7")!, ColorRGBA(hex: "#3B82F6")!, ColorRGBA(hex: "#EC4899")!]
            }
        }

        /// Small lights circling above the ring.
        public var orbs: Int {
            switch self {
            case .electric, .galaxy: return 4
            case .fire, .nature: return 3
            case .none, .gold, .rainbow, .ice, .shadow: return 0
            }
        }

        public var price: Int {
            switch self {
            case .none: return 0
            case .nature, .ice, .shadow: return 300
            case .fire, .electric: return 400
            case .gold: return 500
            case .rainbow, .galaxy: return 700
            }
        }
    }

    /// Eyes and mouth, drawn on the front of the head.
    public enum Face: String, Codable, CaseIterable, Sendable {
        case smile, grin, wink, cool, surprised, sleepy, cat, robot, heart
        // Added later; see `legacy`.
        case angry, sad, tongue
        case starEyes = "star_eyes"
        case dizzy, glasses, monocle, blush, alien, eyepatch, ninja, joy, mustache, fangs, happy

        /// The faces every version of Ablox knows. Others travel under their
        /// own key, so an iPad that has not updated still reads the profile.
        public static let legacy: Set<Face> = [.smile, .grin, .wink, .cool, .surprised, .sleepy, .cat, .robot, .heart]

        /// The English name, kept as the original for the shop and
        /// translated when shown.
        public var englishName: String {
            switch self {
            case .smile: return "Smile"
            case .grin: return "Grin"
            case .wink: return "Wink"
            case .cool: return "Sunglasses"
            case .surprised: return "Surprised"
            case .sleepy: return "Sleepy"
            case .cat: return "Cat"
            case .robot: return "Robot"
            case .heart: return "Heart eyes"
            case .angry: return "Angry"
            case .sad: return "Sad"
            case .tongue: return "Tongue out"
            case .starEyes: return "Star eyes"
            case .dizzy: return "Dizzy"
            case .glasses: return "Round glasses"
            case .monocle: return "Monocle"
            case .blush: return "Blushing"
            case .alien: return "Alien"
            case .eyepatch: return "Eyepatch"
            case .ninja: return "Ninja mask"
            case .joy: return "Tears of joy"
            case .mustache: return "Moustache"
            case .fangs: return "Fangs"
            case .happy: return "Happy"
            }
        }

        public var displayName: String { L(englishName) }

        public var symbolName: String {
            switch self {
            case .smile: return "face.smiling"
            case .grin: return "face.smiling.inverse"
            case .wink: return "eye"
            case .cool: return "sunglasses"
            case .surprised: return "exclamationmark.bubble"
            case .sleepy: return "moon.zzz"
            case .cat: return "cat"
            case .robot: return "cpu"
            case .heart: return "heart.circle"
            case .angry: return "flame"
            case .sad: return "cloud.rain"
            case .tongue: return "mouth"
            case .starEyes: return "star.circle"
            case .dizzy: return "tornado"
            case .glasses: return "eyeglasses"
            case .monocle: return "circle.dashed"
            case .blush: return "heart.text.square"
            case .alien: return "sparkles"
            case .eyepatch: return "eye.slash"
            case .ninja: return "theatermasks"
            case .joy: return "drop"
            case .mustache: return "mustache"
            case .fangs: return "moon.stars"
            case .happy: return "sun.max"
            }
        }

        public var price: Int {
            switch self {
            case .smile, .grin: return 0
            case .wink, .happy: return 30
            case .surprised, .sleepy, .sad, .tongue, .blush: return 40
            case .angry, .glasses, .dizzy: return 60
            case .cool, .mustache, .eyepatch: return 80
            case .monocle, .joy, .fangs: return 100
            case .cat, .robot, .ninja: return 120
            case .alien, .starEyes: return 140
            case .heart: return 160
            }
        }
    }

    /// A small friend that follows along.
    public enum Pet: String, Codable, CaseIterable, Sendable {
        case none, cat, dog, bunny, bird, slime, robot, dragon
        // Added later; see `legacy`.
        case fox, panda, penguin, frog, turtle, duck, bee, ghost, unicorn, owl

        /// The pets every version of Ablox knows.
        public static let legacy: Set<Pet> = [.none, .cat, .dog, .bunny, .bird, .slime, .robot, .dragon]

        public var englishName: String {
            switch self {
            case .none: return "None"
            default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }

        public var displayName: String {
            switch self {
            case .none: return L("None")
            case .cat: return L("Cat")
            case .dog: return L("Dog")
            case .bunny: return L("Bunny")
            case .bird: return L("Bird")
            case .slime: return L("Slime")
            case .robot: return L("Robot")
            case .dragon: return L("Dragon")
            case .fox: return L("Fox")
            case .panda: return L("Panda")
            case .penguin: return L("Penguin")
            case .frog: return L("Frog")
            case .turtle: return L("Turtle")
            case .duck: return L("Duck")
            case .bee: return L("Bee")
            case .ghost: return L("Ghost")
            case .unicorn: return L("Unicorn")
            case .owl: return L("Owl")
            }
        }

        public var symbolName: String {
            switch self {
            case .none: return "nosign"
            case .cat: return "cat.fill"
            case .dog: return "dog.fill"
            case .bunny: return "hare.fill"
            case .bird: return "bird.fill"
            case .slime: return "drop.fill"
            case .robot: return "cpu.fill"
            case .dragon: return "flame.fill"
            case .fox: return "pawprint.fill"
            case .panda: return "circle.hexagongrid.fill"
            case .penguin: return "snowflake"
            case .frog: return "leaf.fill"
            case .turtle: return "tortoise.fill"
            case .duck: return "drop.halffull"
            case .bee: return "ant.fill"
            case .ghost: return "cloud.fill"
            case .unicorn: return "sparkles"
            case .owl: return "moon.fill"
            }
        }

        /// Flying pets sit by the shoulder rather than at the feet.
        public var flies: Bool { [.bird, .dragon, .bee, .ghost, .owl].contains(self) }

        public var price: Int {
            switch self {
            case .none: return 0
            case .cat, .dog, .frog, .duck: return 150
            case .bunny, .turtle, .penguin: return 200
            case .bird, .fox, .bee: return 250
            case .slime, .panda, .owl: return 300
            case .robot, .ghost: return 400
            case .dragon, .unicorn: return 600
            }
        }
    }

    /// Something a character rides, drawn around the avatar.
    public enum Ride: String, Codable, CaseIterable, Sendable {
        case none, car, sports, truck, kart, bike, scooter, jetpack, hoverboard

        /// Sitting down in it, rather than standing on or wearing it.
        public var isSeated: Bool {
            switch self {
            case .car, .sports, .truck, .kart: return true
            case .none, .bike, .scooter, .jetpack, .hoverboard: return false
            }
        }
    }

    public enum HatStyle: String, Codable, CaseIterable, Sendable {
        case none, cap, crown, antenna, halo
        // Added later; see `legacy`.
        case topHat = "top_hat", beanie, cowboy, wizard, pirate, chef, party, headphones
        case bunnyEars = "bunny_ears", horns
        case flowerCrown = "flower_crown", bow, helmet, viking, beret, propeller, graduate, santa, witch, headband

        /// The hats every version of Ablox knows. Others travel under their
        /// own key, so an iPad that has not updated still reads the profile.
        public static let legacy: [HatStyle] = [.none, .cap, .crown, .antenna, .halo]

        public var englishName: String {
            switch self {
            case .none: return "None"
            case .cap: return "Cap"
            case .crown: return "Crown"
            case .antenna: return "Antenna"
            case .halo: return "Halo"
            case .topHat: return "Top hat"
            case .beanie: return "Beanie"
            case .cowboy: return "Cowboy hat"
            case .wizard: return "Wizard hat"
            case .pirate: return "Pirate hat"
            case .chef: return "Chef's hat"
            case .party: return "Party hat"
            case .headphones: return "Headphones"
            case .bunnyEars: return "Bunny ears"
            case .horns: return "Horns"
            case .flowerCrown: return "Flower crown"
            case .bow: return "Ribbon bow"
            case .helmet: return "Helmet"
            case .viking: return "Viking helmet"
            case .beret: return "Beret"
            case .propeller: return "Propeller cap"
            case .graduate: return "Graduation cap"
            case .santa: return "Santa hat"
            case .witch: return "Witch hat"
            case .headband: return "Headband"
            }
        }

        public var displayName: String { L(englishName) }

        public var symbolName: String {
            switch self {
            case .none: return "nosign"
            case .cap: return "cap.fill"
            case .crown: return "crown.fill"
            case .antenna: return "antenna.radiowaves.left.and.right"
            case .halo: return "circle.circle"
            case .topHat, .cowboy, .beret, .santa: return "hat.widebrim.fill"
            case .beanie, .headband: return "circle.bottomhalf.filled"
            case .wizard, .witch, .party: return "triangle.fill"
            case .pirate: return "flag.fill"
            case .chef: return "fork.knife"
            case .headphones: return "headphones"
            case .bunnyEars: return "hare"
            case .horns: return "bolt.fill"
            case .flowerCrown: return "camera.macro"
            case .bow: return "gift.fill"
            case .helmet, .viking: return "shield.fill"
            case .propeller: return "fan.fill"
            case .graduate: return "graduationcap.fill"
            }
        }

        public var price: Int {
            switch self {
            case .none: return 0
            // The first four kept their price.
            case .cap, .crown, .antenna, .halo: return 75
            case .beanie, .headband: return 60
            case .bow, .party, .beret: return 75
            case .headphones, .bunnyEars, .chef: return 100
            case .cowboy, .pirate, .propeller, .flowerCrown: return 120
            case .topHat, .helmet, .graduate, .santa: return 150
            case .wizard, .witch, .horns: return 180
            case .viking: return 250
            }
        }
    }

    public static let `default` = AvatarProfile()

    /// A deterministic, distinguishable look derived from a peer id, used for
    /// players who never opened the avatar editor.
    ///
    /// Every attribute is derived from a hash of **all sixteen** id bytes
    /// under a different seed. Indexing individual bytes instead would give
    /// identical avatars to any two peers whose ids share a prefix, which is
    /// exactly what happens when ids are minted somewhere other than
    /// `UUID()` — a test peer, a replay fixture, a future deterministic id.
    ///
    /// `Hasher` is deliberately not used: it is randomly seeded per process,
    /// so the same peer would look different on every iPad.
    public static func generated(for peer: PeerID, name: String) -> AvatarProfile {
        let palette = Array(ColorRGBA.originalPalette)
        // The original hats only, so every version draws the same look.
        let hats = HatStyle.legacy
        return AvatarProfile(
            displayName: name,
            bodyColor: palette[Int(peer.stableHash(seed: 0x9E37) % UInt64(palette.count))],
            headColor: palette[Int(peer.stableHash(seed: 0x85EB) % UInt64(palette.count))],
            accentColor: palette[Int(peer.stableHash(seed: 0xC2B2) % UInt64(palette.count))],
            hat: hats[Int(peer.stableHash(seed: 0x27D4) % UInt64(hats.count))],
            height: 0.9 + Float(peer.stableHash(seed: 0x1656) % 20) / 100
        )
    }
}

// MARK: - PlayerSnapshot

/// One player's authoritative-ish state, as replicated over the wire.
///
/// Ablox uses host-relayed peer authority: each client owns its own avatar's
/// transform and the host forwards it. That keeps latency low on a local mesh
/// and avoids writing prediction/reconciliation, at the cost of trusting
/// peers — acceptable for a friends-in-the-same-room product, and noted in
/// `docs/networking.md`.
public struct PlayerSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var peerID: PeerID
    public var profile: AvatarProfile
    public var position: Vec3
    public var yawDegrees: Float
    public var velocity: Vec3
    public var isGrounded: Bool
    public var score: Int
    public var isReady: Bool
    /// A character a script created and the host moves — not a person. Drawn
    /// like everyone else, left off the scoreboard.
    public var isNPC: Bool
    /// Hidden by a script: still in the game, not drawn.
    public var isHidden: Bool
    /// The team the host or the game put them on; empty for none.
    public var team: String

    public var id: PeerID { peerID }

    public init(
        peerID: PeerID,
        profile: AvatarProfile = .default,
        position: Vec3 = .zero,
        yawDegrees: Float = 0,
        velocity: Vec3 = .zero,
        isGrounded: Bool = true,
        score: Int = 0,
        isReady: Bool = false,
        isNPC: Bool = false,
        isHidden: Bool = false,
        team: String = ""
    ) {
        self.peerID = peerID
        self.profile = profile
        self.position = position
        self.yawDegrees = yawDegrees
        self.velocity = velocity
        self.isGrounded = isGrounded
        self.score = score
        self.isReady = isReady
        self.isNPC = isNPC
        self.isHidden = isHidden
        self.team = team
    }

    private enum CodingKeys: String, CodingKey {
        case peerID, profile, position, yawDegrees, velocity, isGrounded, score, isReady, isNPC, isHidden, team
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peerID = try c.decode(PeerID.self, forKey: .peerID)
        profile = try c.decode(AvatarProfile.self, forKey: .profile)
        position = try c.decode(Vec3.self, forKey: .position)
        yawDegrees = try c.decode(Float.self, forKey: .yawDegrees)
        velocity = try c.decode(Vec3.self, forKey: .velocity)
        isGrounded = try c.decode(Bool.self, forKey: .isGrounded)
        score = try c.decode(Int.self, forKey: .score)
        isReady = try c.decode(Bool.self, forKey: .isReady)
        isNPC = try c.decodeIfPresent(Bool.self, forKey: .isNPC) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        team = String((try c.decodeIfPresent(String.self, forKey: .team) ?? "").prefix(32))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(peerID, forKey: .peerID)
        try c.encode(profile, forKey: .profile)
        try c.encode(position, forKey: .position)
        try c.encode(yawDegrees, forKey: .yawDegrees)
        try c.encode(velocity, forKey: .velocity)
        try c.encode(isGrounded, forKey: .isGrounded)
        try c.encode(score, forKey: .score)
        try c.encode(isReady, forKey: .isReady)
        try c.encode(isNPC, forKey: .isNPC)
        try c.encode(isHidden, forKey: .isHidden)
        if !team.isEmpty { try c.encode(team, forKey: .team) }
    }
}

// MARK: - Interpolation

public extension PlayerSnapshot {
    /// Blends toward `target` for smoothing remote avatars between the ~15 Hz
    /// transform packets. Yaw uses shortest-arc so an avatar crossing 180°
    /// does not spin the long way.
    func interpolated(toward target: PlayerSnapshot, t: Float) -> PlayerSnapshot {
        var result = target
        result.position = Vec3.lerp(position, target.position, t)
        result.yawDegrees = normalizeDegrees(yawDegrees + angularDelta(from: yawDegrees, to: target.yawDegrees) * t)
        result.velocity = Vec3.lerp(velocity, target.velocity, t)
        return result
    }
}

// MARK: - Movement

/// Player movement tuning. Exposed as data so Settings can offer a "floaty /
/// snappy" slider without touching the controller.
public struct MovementConfig: Codable, Hashable, Sendable {
    public var walkSpeed: Float
    public var runMultiplier: Float
    public var jumpSpeed: Float
    public var gravity: Float
    public var airControl: Float
    /// Metres per second of horizontal damping applied when the stick is idle.
    public var groundFriction: Float
    public var maxFallSpeed: Float
    public var turnSpeedDegreesPerSecond: Float

    public init(
        walkSpeed: Float = 5.0,
        runMultiplier: Float = 1.8,
        jumpSpeed: Float = 6.0,
        gravity: Float = -18.0,
        airControl: Float = 0.45,
        groundFriction: Float = 12.0,
        maxFallSpeed: Float = -45.0,
        turnSpeedDegreesPerSecond: Float = 540
    ) {
        self.walkSpeed = walkSpeed
        self.runMultiplier = runMultiplier
        self.jumpSpeed = jumpSpeed
        self.gravity = gravity
        self.airControl = airControl
        self.groundFriction = groundFriction
        self.maxFallSpeed = maxFallSpeed
        self.turnSpeedDegreesPerSecond = turnSpeedDegreesPerSecond
    }

    // MARK: What a player can actually reach
    //
    // Derived from the numbers above rather than written down beside them, so
    // they cannot drift apart. Studio quotes these when it asks an assistant
    // for a level: an assistant told "you can jump 1 m" does not place a 3 m
    // step, and a level nobody can finish is the failure that matters here.
    //
    // `CharacterSolverTests` checks them against the simulation itself.

    /// How high a standing jump reaches, in metres: v² / 2g.
    public var maximumJumpHeight: Float {
        guard gravity < 0 else { return 0 }
        return (jumpSpeed * jumpSpeed) / (2 * -gravity)
    }

    /// How long a jump lasts, take-off to landing on the same height.
    public var airTime: Float {
        guard gravity < 0 else { return 0 }
        return 2 * jumpSpeed / -gravity
    }

    /// How far a jump carries horizontally on flat ground.
    ///
    /// The real figure is a little shorter, because air control is partial and
    /// the stick is rarely held perfectly — so a gap built to exactly this is
    /// a gap that is missed half the time. `safeJumpDistance` is what Studio
    /// quotes.
    public func maximumJumpDistance(running: Bool) -> Float {
        (running ? walkSpeed * runMultiplier : walkSpeed) * airTime
    }

    /// The gap a player clears reliably rather than occasionally: three
    /// quarters of a running jump.
    public var safeJumpDistance: Float {
        maximumJumpDistance(running: true) * 0.75
    }

    public static let `default` = MovementConfig()
}

/// Per-frame player intent, produced by the on-screen joystick (or, in the
/// Studio's preview, by a keyboard).
public struct MovementInput: Hashable, Sendable {
    /// Stick offset in `-1...1` on each axis. `y` is forward.
    public var stick: Vec3
    public var isJumping: Bool
    public var isRunning: Bool
    /// Camera yaw, so "forward" means "away from the camera".
    public var cameraYawDegrees: Float

    public init(stick: Vec3 = .zero, isJumping: Bool = false, isRunning: Bool = false, cameraYawDegrees: Float = 0) {
        self.stick = stick
        self.isJumping = isJumping
        self.isRunning = isRunning
        self.cameraYawDegrees = cameraYawDegrees
    }

    public static let idle = MovementInput()

    /// Stick magnitude, clamped to 1 so diagonals are not faster.
    public var magnitude: Float {
        Swift.min(1, Vec3(stick.x, 0, stick.z).length)
    }
}

/// Character motion, solved in plain Swift so it is unit-testable and
/// identical on host and client. RealityKit applies the result; it does not
/// decide it.
public enum CharacterSolver {
    /// Advances horizontal velocity and applies gravity for one step.
    ///
    /// - Parameters:
    ///   - snapshot: current player state.
    ///   - input: this frame's intent.
    ///   - config: tuning.
    ///   - deltaTime: seconds since the last step, clamped by the caller.
    /// - Returns: the new velocity and facing, with position left to the
    ///   collision pass that owns it.
    public static func step(
        snapshot: PlayerSnapshot,
        input: MovementInput,
        config: MovementConfig = .default,
        surroundings: Surroundings = .normal,
        floats: Bool = false,
        deltaTime: Float
    ) -> (velocity: Vec3, yawDegrees: Float) {
        let dt = Swift.max(0, Swift.min(deltaTime, 0.1))

        switch surroundings {
        case .normal:
            break
        case let .water(surface):
            return swim(snapshot: snapshot, input: input, config: config, surface: surface, floats: floats, dt: dt)
        case .ladder:
            return climb(snapshot: snapshot, input: input, config: config, dt: dt)
        }

        // Rotate the stick into world space around the camera.
        let cameraYaw = Quat.yaw(degrees: input.cameraYawDegrees)
        let desiredDirection = cameraYaw.act(Vec3(input.stick.x, 0, -input.stick.z)).normalized
        let magnitude = input.magnitude

        let targetSpeed = config.walkSpeed * (input.isRunning ? config.runMultiplier : 1) * magnitude
        let targetVelocity = desiredDirection * targetSpeed

        var horizontal = Vec3(snapshot.velocity.x, 0, snapshot.velocity.z)
        if snapshot.isGrounded {
            if magnitude > 0.01 {
                horizontal = targetVelocity
            } else {
                // Decay toward a stop rather than snapping, so letting go of
                // the stick still feels weighty.
                let decay = Swift.max(0, 1 - config.groundFriction * dt)
                horizontal = horizontal * decay
            }
        } else {
            // In the air the player only nudges their trajectory.
            horizontal = Vec3.lerp(horizontal, targetVelocity, Swift.min(1, config.airControl * dt * 6))
        }

        var verticalSpeed = snapshot.velocity.y
        if input.isJumping && snapshot.isGrounded {
            verticalSpeed = config.jumpSpeed
        } else {
            verticalSpeed = Swift.max(config.maxFallSpeed, verticalSpeed + config.gravity * dt)
        }

        // Face the way we are moving; keep the old facing when standing still.
        var yaw = snapshot.yawDegrees
        if magnitude > 0.01 {
            let targetYaw = atan2(desiredDirection.x, -desiredDirection.z) * 180 / .pi
            let delta = angularDelta(from: yaw, to: targetYaw)
            let maxStep = config.turnSpeedDegreesPerSecond * dt
            yaw = normalizeDegrees(yaw + Swift.max(-maxStep, Swift.min(maxStep, delta)))
        }

        return (Vec3(horizontal.x, verticalSpeed, horizontal.z), yaw)
    }

    /// Where the stick points, in the world, and how far it is pushed.
    private static func direction(_ input: MovementInput) -> (Vec3, Float) {
        let cameraYaw = Quat.yaw(degrees: input.cameraYawDegrees)
        return (cameraYaw.act(Vec3(input.stick.x, 0, -input.stick.z)).normalized, input.magnitude)
    }

    private static func turned(_ yaw: Float, toward direction: Vec3, magnitude: Float, config: MovementConfig, dt: Float) -> Float {
        guard magnitude > 0.01 else { return yaw }
        let targetYaw = atan2(direction.x, -direction.z) * 180 / .pi
        let delta = angularDelta(from: yaw, to: targetYaw)
        let maxStep = config.turnSpeedDegreesPerSecond * dt
        return normalizeDegrees(yaw + Swift.max(-maxStep, Swift.min(maxStep, delta)))
    }

    /// In water: slower, sinking gently, and jump swims up. A boat (`floats`)
    /// rides on the surface instead.
    static func swim(snapshot: PlayerSnapshot, input: MovementInput, config: MovementConfig, surface: Float, floats: Bool,
                     dt: Float) -> (velocity: Vec3, yawDegrees: Float) {
        let (direction, magnitude) = direction(input)
        let speed = config.walkSpeed * (floats ? 1.1 : 0.6) * (input.isRunning ? 1.3 : 1) * magnitude
        var horizontal = Vec3(snapshot.velocity.x, 0, snapshot.velocity.z)
        horizontal = Vec3.lerp(horizontal, direction * speed, Swift.min(1, 4 * dt))

        var vertical = snapshot.velocity.y
        let depth = surface - snapshot.position.y
        if floats {
            // Bob at the surface: the hull sits just under it.
            vertical = (depth - 0.3) * 4
        } else if input.isJumping {
            // Up towards the air; out with a hop at the top.
            vertical = depth > 1.3 ? 3.2 : config.jumpSpeed * 0.8
        } else {
            vertical = Swift.max(-2.5, vertical + config.gravity * 0.15 * dt)
        }
        let yaw = turned(snapshot.yawDegrees, toward: direction, magnitude: magnitude, config: config, dt: dt)
        return (Vec3(horizontal.x, vertical, horizontal.z), yaw)
    }

    /// On a ladder: the stick forward climbs, back climbs down, nothing
    /// holds on; jump lets go.
    static func climb(snapshot: PlayerSnapshot, input: MovementInput, config: MovementConfig,
                      dt: Float) -> (velocity: Vec3, yawDegrees: Float) {
        let (direction, magnitude) = direction(input)
        if input.isJumping {
            return (Vec3(-direction.x * 3, config.jumpSpeed * 0.8, -direction.z * 3), snapshot.yawDegrees)
        }
        let climbSpeed: Float = 3.2
        let vertical = input.stick.z * climbSpeed
        let sideways = direction * (config.walkSpeed * 0.4 * magnitude)
        let yaw = turned(snapshot.yawDegrees, toward: direction, magnitude: magnitude, config: config, dt: dt)
        return (Vec3(sideways.x, vertical, sideways.z), yaw)
    }
}
