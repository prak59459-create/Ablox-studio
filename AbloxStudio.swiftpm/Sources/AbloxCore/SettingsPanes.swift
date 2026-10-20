import Foundation

// Settings in groups, the way a Mac's System Settings has them: a list of
// groups down the side with a coloured icon each, and the cards of the one
// picked beside it. A search still looks through every card. Rules here,
// the screen in `SettingsView`.

/// One card on the settings screen.
public enum SettingsCard: String, CaseIterable, Sendable {
    case language, updates, moveSettings, about
    case look, graphics, comfort, seeingAndHearing
    case family
    case games, aimingAndSearching
    case soundLibrary, myMusic
    case controls, controllers, movement
    case playScreen, chat
    case data, storage
    case network
    case problemReports, suggestionBox, aiHelper, tips

    /// Its title, in the language in use.
    public var title: String {
        switch self {
        case .language: return L("Language")
        case .updates: return L("Updates")
        case .moveSettings: return L("Move my settings")
        case .about: return L("About")
        case .look: return L("Look")
        case .graphics: return L("Graphics")
        case .comfort: return L("Comfort")
        case .seeingAndHearing: return L("Seeing and hearing")
        case .family: return L("Family")
        case .games: return L("Games")
        case .aimingAndSearching: return L("Aiming and searching")
        case .soundLibrary: return L("Sound library")
        case .myMusic: return L("My music")
        case .controls: return L("Controls")
        case .controllers: return L("Controllers")
        case .movement: return L("Movement")
        case .playScreen: return L("Play screen")
        case .chat: return L("Chat and names")
        case .data: return L("Data")
        case .storage: return L("Storage")
        case .network: return L("Network")
        case .problemReports: return L("Problem reports")
        case .suggestionBox: return L("Suggestion box")
        case .aiHelper: return L("AI helper")
        case .tips: return L("Tips")
        }
    }

    /// Other words someone might search for it by (English; the title is
    /// searched in the language in use too).
    public var words: String {
        switch self {
        case .language: return "language"
        case .updates: return "update version"
        case .moveSettings: return "move settings file export import another ipad"
        case .about: return "about version"
        case .look: return "look theme colour accent light dark"
        case .graphics: return "graphics quality frame rate"
        case .comfort: return "comfort shake field of view warm dim battery"
        case .seeingAndHearing: return "seeing hearing colour vision bold motion captions speed accessibility"
        case .family: return "family parent passcode limit time chat rooms coins"
        case .games: return "games list catalogue"
        case .aimingAndSearching: return "crosshair hidden games searches birthday"
        case .soundLibrary: return "sound library effects sfx download listen"
        case .myMusic: return "my music song songs bgm plaza lobby"
        case .controls: return "controls joystick camera sensitivity invert"
        case .controllers: return "controller keyboard mouse"
        case .movement: return "movement walk run jump"
        case .playScreen: return "play screen buttons compass map stick"
        case .chat: return "chat bubbles names emoji"
        case .data: return "data backup save restore"
        case .storage: return "storage space delete"
        case .network: return "network wifi internet"
        case .problemReports: return "problem report error crash"
        case .suggestionBox: return "suggestion box idea opinion feedback request bug"
        case .aiHelper: return "ai helper help question robot ablobo how"
        case .tips: return "tips shortcuts keyboard help"
        }
    }

    public func matches(_ query: String) -> Bool {
        SearchText.matches(query, in: [words, title])
    }
}

/// A group of cards, one row in the side list.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, appearance, family, games, sound, controls, playScreen, data, network, help

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return L("General")
        case .appearance: return L("Appearance")
        case .family: return L("Family")
        case .games: return L("Games")
        case .sound: return L("Sound")
        case .controls: return L("Controls")
        case .playScreen: return L("Play screen")
        case .data: return L("Data")
        case .network: return L("Network")
        case .help: return L("Help and ideas")
        }
    }

    /// An SF Symbol, drawn white on `colour` like a Mac's.
    public var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.fill"
        case .family: return "figure.2.and.child.holdinghands"
        case .games: return "gamecontroller.fill"
        case .sound: return "speaker.wave.2.fill"
        case .controls: return "hand.draw.fill"
        case .playScreen: return "rectangle.on.rectangle"
        case .data: return "externaldrive.fill"
        case .network: return "network"
        case .help: return "questionmark.bubble.fill"
        }
    }

    public var colour: ColorRGBA {
        let hex: String
        switch self {
        case .general: hex = "#8E8E93"
        case .appearance: hex = "#5856D6"
        case .family: hex = "#FF9500"
        case .games: hex = "#34C759"
        case .sound: hex = "#FF2D55"
        case .controls: hex = "#007AFF"
        case .playScreen: hex = "#5AC8FA"
        case .data: hex = "#636366"
        case .network: hex = "#0A84FF"
        case .help: hex = "#FFCC00"
        }
        return ColorRGBA(hex: hex) ?? ColorRGBA(r: 0.5, g: 0.5, b: 0.5)
    }

    /// Its cards, top to bottom.
    public var cards: [SettingsCard] {
        switch self {
        case .general: return [.language, .updates, .moveSettings, .about]
        case .appearance: return [.look, .graphics, .comfort, .seeingAndHearing]
        case .family: return [.family]
        case .games: return [.games, .aimingAndSearching]
        case .sound: return [.soundLibrary, .myMusic]
        case .controls: return [.controls, .controllers, .movement]
        case .playScreen: return [.playScreen, .chat]
        case .data: return [.data, .storage]
        case .network: return [.network]
        case .help: return [.problemReports, .suggestionBox, .aiHelper, .tips]
        }
    }

    /// The group a card is in.
    public static func pane(of card: SettingsCard) -> SettingsPane {
        allCases.first { $0.cards.contains(card) } ?? .general
    }

    /// What the screen shows: the picked group's cards, or, while
    /// searching, every card that matches, in side-list order.
    public static func shown(pane: SettingsPane, search: String) -> [SettingsCard] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return pane.cards }
        return allCases.flatMap(\.cards).filter { $0.matches(query) }
    }

    /// Groups with something matching the search, to mark in the side list.
    public static func matching(_ search: String) -> Set<SettingsPane> {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Set(allCases.filter { $0.cards.contains { $0.matches(query) } })
    }
}
