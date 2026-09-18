import Foundation

/// The Ablox icon vocabulary.
///
/// Names come from the project's icon sheet, so the design and the code share
/// one set of words: an icon called `heart-filled` on the sheet is
/// `AbloxIcon.heartFilled` here.
///
/// ## Why this exists rather than SF Symbol names inline
///
/// Symbol names were scattered as string literals across a dozen view files.
/// A typo in one produced a silently blank space at runtime, and there was no
/// way to answer "which icons does this app actually use". Routing every icon
/// through one enum makes the vocabulary a compile-time contract, and means
/// swapping in custom artwork later is an edit to `symbolName` rather than a
/// hunt through the UI layer.
///
/// ## Why it lives in AbloxCore
///
/// It is pure data — names in, names out, no SwiftUI. That keeps it testable
/// off-device alongside the rest of the core, and lets the client and Studio
/// share one vocabulary rather than drifting apart.
///
/// See `hasNativeEquivalent` for the icons where SF Symbols genuinely has
/// nothing suitable; those are the ones worth drawing by hand first.
public enum AbloxIcon: String, CaseIterable, Sendable, Identifiable {

    // MARK: Navigation & interaction

    case arrowUp = "arrow-up"
    case arrowDown = "arrow-down"
    case arrowLeft = "arrow-left"
    case arrowRight = "arrow-right"
    case upLeft = "up-left"
    case upRight = "up-right"
    case downLeft = "down-left"
    case downRight = "down-right"
    case homeFilled = "home-filled"
    case homeOutline = "home-outline"
    case back = "back"
    case forward = "forward"
    case refresh = "refresh"
    case reload = "reload"
    case swap = "swap"
    case menu = "menu"
    case close = "close"
    case chevronUp = "chevron-up"
    case chevronDown = "chevron-down"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case moreVertical = "more-vertical"
    case moreHorizontal = "more-horizontal"
    case grid = "grid"
    case list = "list"
    case layers = "layers"
    case stack = "stack"
    case filter = "filter"
    case sortAsc = "sort-asc"
    case sortDesc = "sort-desc"
    case search = "search"
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"
    case expand = "expand"
    case collapse = "collapse"
    case fullscreen = "fullscreen"
    case minimize = "minimize"
    case maximize = "maximize"
    case select = "select"
    case check = "check"

    // MARK: Content & media

    case image = "image"
    case photo = "photo"
    case camera = "camera"
    case video = "video"
    case playCircle = "play-circle"
    case pauseCircle = "pause-circle"
    case stopCircle = "stop-circle"
    case record = "record"
    case musicNote = "music-note"
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case mute = "mute"
    case headphones = "headphones"
    case mic = "mic"
    case micOff = "mic-off"
    case cast = "cast"
    case tv = "tv"
    case film = "film"
    case clapperboard = "clapperboard"
    case youtube = "youtube"
    case twitch = "twitch"
    case discord = "discord"
    case spotify = "spotify"
    case cloud = "cloud"
    case download = "download"
    case upload = "upload"
    case bookmark = "bookmark"
    case bookmarkFilled = "bookmark-filled"
    case heart = "heart"
    case heartFilled = "heart-filled"
    case star = "star"
    case starFilled = "star-filled"
    case flag = "flag"
    case report = "report"
    case trash = "trash"
    case folder = "folder"
    case folderOpen = "folder-open"
    case document = "document"
    case documentFilled = "document-filled"
    case imageAdd = "image-add"

    // MARK: Social & people

    case person = "person"
    case group = "group"
    case addPerson = "add-person"
    case removePerson = "remove-person"
    case userCheck = "user-check"
    case userX = "user-x"
    case friends = "friends"
    case chatBubble = "chat-bubble"
    case chatBubbles = "chat-bubbles"
    case message = "message"
    case notificationBell = "notification-bell"
    case notificationBellOff = "notification-bell-off"
    case smile = "smile"
    case sad = "sad"
    case laugh = "laugh"
    case angry = "angry"
    case surprised = "surprised"
    case thinking = "thinking"
    case wink = "wink"
    case cool = "cool"
    case handWave = "hand-wave"
    case handshake = "handshake"
    case highFive = "high-five"
    case clap = "clap"
    case thumbsUp = "thumbs-up"
    case thumbsDown = "thumbs-down"
    case fist = "fist"
    case peace = "peace"
    case heartHands = "heart-hands"
    case crown = "crown"
    case medal = "medal"
    case badge = "badge"
    case trophy = "trophy"
    case leaderboard = "leaderboard"
    case calendarPerson = "calendar-person"
    case userPlus = "user-plus"
    case userMinus = "user-minus"
    case blocked = "blocked"
    case eye = "eye"
    case eyeOff = "eye-off"

    // MARK: Game & play

    case gamepad = "gamepad"
    case controller = "controller"
    case joystick = "joystick"
    case keyboard = "keyboard"
    case mouse = "mouse"
    case touch = "touch"
    case crosshair = "crosshair"
    case target = "target"
    case shield = "shield"
    case sword = "sword"
    case bow = "bow"
    case rocket = "rocket"
    case bomb = "bomb"
    case grenade = "grenade"
    case potion = "potion"
    case backpack = "backpack"
    case chest = "chest"
    case key = "key"
    case coin = "coin"
    case gem = "gem"
    case diamond = "diamond"
    case ticket = "ticket"
    case box = "box"
    case gift = "gift"
    case present = "present"
    case shop = "shop"
    case cart = "cart"
    case gearCog = "gear-cog"
    case wrench = "wrench"
    case hammer = "hammer"
    case pickaxe = "pickaxe"
    case axe = "axe"
    case scythe = "scythe"
    case flame = "flame"
    case snowflake = "snowflake"
    case leaf = "leaf"
    case flyingWings = "flying-wings"
    case speed = "speed"

    // MARK: Device & system

    case battery = "battery"
    case batteryCharging = "battery-charging"
    case wifi = "wifi"
    case wifiOff = "wifi-off"
    case bluetooth = "bluetooth"
    case bluetoothOff = "bluetooth-off"
    case signal = "signal"
    case signalOff = "signal-off"
    case airplane = "airplane"
    case location = "location"
    case locationOff = "location-off"
    case lock = "lock"
    case unlock = "unlock"
    case chip = "chip"
    case cpu = "cpu"
    case gpu = "gpu"
    case memory = "memory"
    case sdCard = "sd-card"
    case hardDrive = "hard-drive"
    case printer = "printer"
    case projector = "projector"
    case monitor = "monitor"
    case laptop = "laptop"
    case phone = "phone"
    case tablet = "tablet"
    case web = "web"
    case globe = "globe"
    case language = "language"
    case palette = "palette"
    case brightness = "brightness"
    case darkMode = "dark-mode"
    case lightMode = "light-mode"
    case temperature = "temperature"
    case thermometer = "thermometer"
    case volume = "volume"
    case microphone = "microphone"
    case command = "command"
    case power = "power"

    // MARK: Misc & special

    case question = "question"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case success = "success"
    case plus = "plus"
    case minus = "minus"
    case equals = "equals"
    case percent = "percent"
    case currency = "currency"
    case time = "time"
    case date = "date"
    case clock = "clock"
    case hourglass = "hourglass"
    case infinity = "infinity"
    case magicWand = "magic-wand"
    case wand = "wand"
    case sparkle = "sparkle"
    case fireworks = "fireworks"
    case planet = "planet"
    case starburst = "starburst"
    case sun = "sun"
    case moon = "moon"
    case cloudRain = "cloud-rain"
    case cloudSnow = "cloud-snow"
    case rainbow = "rainbow"
    case tree = "tree"
    case mountain = "mountain"
    case waterDrop = "water-drop"
    case waves = "waves"
    case plant = "plant"
    case recycle = "recycle"
    case compass = "compass"
    case map = "map"
    case paperPlane = "paper-plane"
    case rss = "rss"
    public var id: String { rawValue }

    /// The SF Symbol this icon renders as today.
    ///
    /// Every case resolves to something drawable — there is no `nil` path and
    /// no empty string, so a view can never end up with an invisible glyph.
    /// Where SF Symbols has no true match the value is a deliberate stand-in;
    /// `hasNativeEquivalent` tells them apart.
    public var symbolName: String {
        switch self {

        // Navigation & interaction
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        case .upLeft: return "arrow.up.left"
        case .upRight: return "arrow.up.right"
        case .downLeft: return "arrow.down.left"
        case .downRight: return "arrow.down.right"
        case .homeFilled: return "house.fill"
        case .homeOutline: return "house"
        case .back: return "chevron.backward"
        case .forward: return "chevron.forward"
        case .refresh: return "arrow.clockwise"
        case .reload: return "arrow.triangle.2.circlepath"
        case .swap: return "arrow.left.arrow.right"
        case .menu: return "line.3.horizontal"
        case .close: return "xmark"
        case .chevronUp: return "chevron.up"
        case .chevronDown: return "chevron.down"
        case .chevronLeft: return "chevron.left"
        case .chevronRight: return "chevron.right"
        case .moreVertical: return "ellipsis.vertical"
        case .moreHorizontal: return "ellipsis"
        case .grid: return "square.grid.2x2.fill"
        case .list: return "list.bullet"
        case .layers: return "square.3.layers.3d"
        case .stack: return "square.stack.3d.up.fill"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .sortAsc: return "arrow.up.to.line"
        case .sortDesc: return "arrow.down.to.line"
        case .search: return "magnifyingglass"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .collapse: return "arrow.down.right.and.arrow.up.left"
        case .fullscreen: return "viewfinder"
        case .minimize: return "minus"
        case .maximize: return "square.dashed"
        case .select: return "cursorarrow"
        case .check: return "checkmark"

        // Content & media
        case .image: return "photo"
        case .photo: return "photo.on.rectangle"
        case .camera: return "camera.fill"
        case .video: return "video.fill"
        case .playCircle: return "play.circle.fill"
        case .pauseCircle: return "pause.circle.fill"
        case .stopCircle: return "stop.circle.fill"
        case .record: return "record.circle.fill"
        case .musicNote: return "music.note"
        case .volumeUp: return "speaker.wave.2.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .headphones: return "headphones"
        case .mic: return "mic.fill"
        case .micOff: return "mic.slash.fill"
        case .cast: return "airplayvideo"
        case .tv: return "tv.fill"
        case .film: return "film.fill"
        case .clapperboard: return "film.stack"
        case .youtube: return "play.rectangle.fill"
        case .twitch: return "gamecontroller.fill"
        case .discord: return "bubble.left.and.bubble.right.fill"
        case .spotify: return "music.note.list"
        case .cloud: return "cloud.fill"
        case .download: return "arrow.down.circle.fill"
        case .upload: return "arrow.up.circle.fill"
        case .bookmark: return "bookmark"
        case .bookmarkFilled: return "bookmark.fill"
        case .heart: return "heart"
        case .heartFilled: return "heart.fill"
        case .star: return "star"
        case .starFilled: return "star.fill"
        case .flag: return "flag.fill"
        case .report: return "exclamationmark.bubble.fill"
        case .trash: return "trash.fill"
        case .folder: return "folder.fill"
        case .folderOpen: return "folder.fill"
        case .document: return "doc"
        case .documentFilled: return "doc.fill"
        case .imageAdd: return "photo.badge.plus"

        // Social & people
        case .person: return "person.fill"
        case .group: return "person.3.fill"
        case .addPerson: return "person.badge.plus"
        case .removePerson: return "person.badge.minus"
        case .userCheck: return "person.fill.checkmark"
        case .userX: return "person.fill.xmark"
        case .friends: return "person.2.fill"
        case .chatBubble: return "bubble.left.fill"
        case .chatBubbles: return "bubble.left.and.bubble.right.fill"
        case .message: return "message.fill"
        case .notificationBell: return "bell.fill"
        case .notificationBellOff: return "bell.slash.fill"
        case .smile: return "face.smiling"
        case .sad: return "face.dashed"
        case .laugh: return "face.smiling.inverse"
        case .angry: return "face.dashed.fill"
        case .surprised: return "face.dashed"
        case .thinking: return "face.dashed"
        case .wink: return "face.smiling"
        case .cool: return "face.smiling.inverse"
        case .handWave: return "hand.wave.fill"
        case .handshake: return "hands.clap.fill"
        case .highFive: return "hand.raised.fill"
        case .clap: return "hands.clap.fill"
        case .thumbsUp: return "hand.thumbsup.fill"
        case .thumbsDown: return "hand.thumbsdown.fill"
        case .fist: return "hand.raised.fingers.spread.fill"
        case .peace: return "hand.raised.fingers.spread.fill"
        case .heartHands: return "heart.circle.fill"
        case .crown: return "crown.fill"
        case .medal: return "medal.fill"
        case .badge: return "checkmark.seal.fill"
        case .trophy: return "trophy.fill"
        case .leaderboard: return "chart.bar.fill"
        case .calendarPerson: return "calendar.badge.clock"
        case .userPlus: return "person.crop.circle.badge.plus"
        case .userMinus: return "person.crop.circle.badge.minus"
        case .blocked: return "nosign"
        case .eye: return "eye.fill"
        case .eyeOff: return "eye.slash.fill"

        // Game & play
        case .gamepad: return "gamecontroller.fill"
        case .controller: return "gamecontroller"
        case .joystick: return "l.joystick.tilt.up.fill"
        case .keyboard: return "keyboard.fill"
        case .mouse: return "computermouse.fill"
        case .touch: return "hand.tap.fill"
        case .crosshair: return "scope"
        case .target: return "target"
        case .shield: return "shield.fill"
        case .sword: return "figure.fencing"
        case .bow: return "arrow.up.forward"
        case .rocket: return "paperplane.fill"
        case .bomb: return "circle.fill"
        case .grenade: return "circle.hexagongrid.fill"
        case .potion: return "flask.fill"
        case .backpack: return "backpack.fill"
        case .chest: return "shippingbox.fill"
        case .key: return "key.fill"
        case .coin: return "dollarsign.circle.fill"
        case .gem: return "diamond.fill"
        case .diamond: return "suit.diamond.fill"
        case .ticket: return "ticket.fill"
        case .box: return "shippingbox.fill"
        case .gift: return "gift.fill"
        case .present: return "gift.fill"
        case .shop: return "storefront.fill"
        case .cart: return "cart.fill"
        case .gearCog: return "gearshape.fill"
        case .wrench: return "wrench.adjustable.fill"
        case .hammer: return "hammer.fill"
        case .pickaxe: return "hammer.fill"
        case .axe: return "hammer.fill"
        case .scythe: return "hammer.fill"
        case .flame: return "flame.fill"
        case .snowflake: return "snowflake"
        case .leaf: return "leaf.fill"
        case .flyingWings: return "paperplane.fill"
        case .speed: return "hare.fill"

        // Device & system
        case .battery: return "battery.100percent"
        case .batteryCharging: return "battery.100percent.bolt"
        case .wifi: return "wifi"
        case .wifiOff: return "wifi.slash"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .bluetoothOff: return "dot.radiowaves.left.and.right"
        case .signal: return "chart.bar.fill"
        case .signalOff: return "chart.bar.xaxis"
        case .airplane: return "airplane"
        case .location: return "location.fill"
        case .locationOff: return "location.slash.fill"
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .chip: return "cpu.fill"
        case .cpu: return "cpu"
        case .gpu: return "memorychip.fill"
        case .memory: return "memorychip"
        case .sdCard: return "sdcard.fill"
        case .hardDrive: return "internaldrive.fill"
        case .printer: return "printer.fill"
        case .projector: return "videoprojector.fill"
        case .monitor: return "display"
        case .laptop: return "laptopcomputer"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .web: return "globe"
        case .globe: return "globe.americas.fill"
        case .language: return "character.bubble.fill"
        case .palette: return "paintpalette.fill"
        case .brightness: return "sun.max.fill"
        case .darkMode: return "moon.fill"
        case .lightMode: return "sun.max.fill"
        case .temperature: return "thermometer.medium"
        case .thermometer: return "thermometer.high"
        case .volume: return "speaker.wave.3.fill"
        case .microphone: return "mic.circle.fill"
        case .command: return "command"
        case .power: return "power"

        // Misc & special
        case .question: return "questionmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        case .plus: return "plus"
        case .minus: return "minus"
        case .equals: return "equal"
        case .percent: return "percent"
        case .currency: return "eurosign.circle.fill"
        case .time: return "clock.fill"
        case .date: return "calendar"
        case .clock: return "clock"
        case .hourglass: return "hourglass"
        case .infinity: return "infinity"
        case .magicWand: return "wand.and.stars"
        case .wand: return "wand.and.rays"
        case .sparkle: return "sparkles"
        case .fireworks: return "sparkles"
        case .planet: return "globe.europe.africa.fill"
        case .starburst: return "sparkle"
        case .sun: return "sun.max.fill"
        case .moon: return "moon.fill"
        case .cloudRain: return "cloud.rain.fill"
        case .cloudSnow: return "cloud.snow.fill"
        case .rainbow: return "rainbow"
        case .tree: return "tree.fill"
        case .mountain: return "mountain.2.fill"
        case .waterDrop: return "drop.fill"
        case .waves: return "water.waves"
        case .plant: return "leaf.fill"
        case .recycle: return "arrow.3.trianglepath"
        case .compass: return "safari.fill"
        case .map: return "map.fill"
        case .paperPlane: return "paperplane.fill"
        case .rss: return "dot.radiowaves.up.forward"
        }
    }

    /// Whether `symbolName` is a genuine match rather than a stand-in.
    ///
    /// `false` means SF Symbols has nothing that really means this icon — a
    /// brand mark, a facial expression, a game object like a potion or a
    /// pickaxe. These are the icons where custom artwork earns its keep, and
    /// the list is deliberately explicit so it can be worked through rather
    /// than rediscovered.
    public var hasNativeEquivalent: Bool {
        !Self.standInIcons.contains(self)
    }

    /// Icons whose SF Symbol is an approximation. See `hasNativeEquivalent`.
    public static let standInIcons: Set<AbloxIcon> = [
        .angry,
        .axe,
        .bluetooth,
        .bluetoothOff,
        .bomb,
        .bow,
        .calendarPerson,
        .chest,
        .coin,
        .compass,
        .cool,
        .discord,
        .fireworks,
        .fist,
        .flyingWings,
        .folderOpen,
        .gpu,
        .grenade,
        .handshake,
        .heartHands,
        .highFive,
        .joystick,
        .laugh,
        .lightMode,
        .peace,
        .pickaxe,
        .planet,
        .plant,
        .potion,
        .present,
        .projector,
        .rocket,
        .sad,
        .scythe,
        .signal,
        .signalOff,
        .spotify,
        .surprised,
        .sword,
        .thinking,
        .twitch,
        .wink,
        .youtube,
    ]

    /// The icons a custom icon set would have to supply to add real value,
    /// in vocabulary order.
    public static var needingCustomArtwork: [AbloxIcon] {
        allCases.filter { !$0.hasNativeEquivalent }
    }
}
