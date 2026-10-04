import Foundation

// How a player looks, in a file of its own. More than half the app uses
// it, so anything else declared beside it — the movement rules, still in
// Player.swift — would rebuild all of that after an update that touched it.

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
    /// The card behind their name, and the bubble round what they say.
    public var nameplate: NamePlate
    public var bubble: BubbleStyle

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
        aura: Aura = .none,
        nameplate: NamePlate = .classic,
        bubble: BubbleStyle = .classic
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
        self.nameplate = nameplate
        self.bubble = bubble
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, bodyColor, headColor, accentColor, hat, height, ride, rideColor, title, face, hatColor, pet, petColor
        case hatNew, faceNew, petNew, trail, aura, nameplate, bubble
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
        nameplate = (try? c.decodeIfPresent(NamePlate.self, forKey: .nameplate)) ?? .classic
        bubble = (try? c.decodeIfPresent(BubbleStyle.self, forKey: .bubble)) ?? .classic
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
        if nameplate != .classic { try c.encode(nameplate, forKey: .nameplate) }
        if bubble != .classic { try c.encode(bubble, forKey: .bubble) }
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
