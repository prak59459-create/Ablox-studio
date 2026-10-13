/// How much room the window has, and what the menus and play screen do
/// with it.
///
/// Ablox is drawn for an iPad, but the same app runs on an iPhone (and in a
/// narrow Split View on an iPad). There the iPad's 264-point sidebar would
/// take a third of the screen and the side panels would cover the game, so
/// a small window gets the compact layout: an icons-only sidebar, narrower
/// panels and a map that fits.
///
/// Plain numbers rather than CGSize so it can be tested off-device.
public struct ScreenFit: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// The smallest iPad window in full screen is 744 points wide (iPad mini
    /// in portrait); an iPhone in landscape is at most about 440 points tall.
    public static let compactWidth: Double = 600
    public static let compactHeight: Double = 500

    /// An iPhone, or an iPad window too small for the iPad layout.
    public var isCompact: Bool {
        width < Self.compactWidth || height < Self.compactHeight
    }

    /// The main menu's sidebar: names beside the icons on an iPad, icons
    /// alone on an iPhone.
    public var sidebarWidth: Double { isCompact ? 76 : 264 }

    /// Whether the sidebar has room for the tab names, the logo and the
    /// connection status.
    public var showsTabNames: Bool { !isCompact }

    /// The space kept around the content of a page.
    public var gutter: Double { isCompact ? 14 : 28 }

    /// The narrowest a card in a grid of cards may be: the size it was drawn
    /// at on an iPad, but on a small screen never wider than the page beside
    /// the sidebar (less its margins and a panel's own padding), so one column
    /// always fits instead of running off the edge.
    public func cardMinimum(_ preferred: Double) -> Double {
        guard isCompact else { return preferred }
        let room = width - sidebarWidth - gutter * 4
        return max(140, min(preferred, room))
    }

    /// A panel beside the game or the avatar (player list, avatar editor):
    /// the size it was drawn at on an iPad, but on a small screen never more
    /// than `share` of the width, so the rest stays visible.
    public func sidePanel(_ preferred: Double, share: Double = 0.45) -> Double {
        guard isCompact else { return preferred }
        return max(200, min(preferred, width * share))
    }

    /// Something square in the middle of the screen (the big map): the size
    /// it was drawn at, or smaller so it fits with a margin.
    public func square(_ preferred: Double, margin: Double = 24) -> Double {
        let room = min(width, height) - margin * 2
        return max(120, min(preferred, room))
    }
}
