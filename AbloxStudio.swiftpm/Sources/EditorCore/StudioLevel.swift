import Foundation

/// How much of Studio is on screen: three levels, so a first-time builder
/// meets three tools and a grid, and an old hand keeps everything.
///
/// - **Easy**: pick, move and paint, on a 1 m grid turning in quarter turns.
///   The rules and the scripts are put away; the Inspector stays.
/// - **Normal**: every building tool, the snapping choices and the rules.
/// - **Pro**: everything — the ground tool and the scripts too.
///
/// Only what is shown changes. A world made at one level opens at any other
/// exactly as it is, and nothing in it is lost by going down a level.
public enum StudioLevel: String, CaseIterable, Sendable, Identifiable {
    case easy, normal, pro

    public var id: String { rawValue }

    /// `UserDefaults`: the level chosen, kept for next time.
    public static let key = "ablox.studioLevel"

    /// Before levels, Studio showed everything: an iPad that has built
    /// before keeps that.
    public static let standard: StudioLevel = .pro

    public var displayName: String {
        switch self {
        case .easy: return L("Easy")
        case .normal: return L("Normal")
        case .pro: return L("Pro")
        }
    }

    public var detail: String {
        switch self {
        case .easy: return L("Pick, move and paint parts, on a 1 m grid.")
        case .normal: return L("Every building tool, snapping and the rules.")
        case .pro: return L("Everything, with the ground tool and scripts.")
        }
    }

    /// The tools on the bar, in its order.
    public var tools: [EditorDocument.Tool] {
        switch self {
        case .easy: return [.select, .move, .paint]
        case .normal: return [.select, .move, .rotate, .scale, .boxSelect, .paint, .eyedropper]
        case .pro: return EditorDocument.Tool.allCases
        }
    }

    public func allows(_ tool: EditorDocument.Tool) -> Bool { tools.contains(tool) }

    /// The grid and angle choices on the bar.
    public var showsSnapping: Bool { self != .easy }
    public var showsRules: Bool { self != .easy }
    public var showsScripts: Bool { self == .pro }

    /// Easy builds on a fixed grid: whole metres and quarter turns, so parts
    /// line up without anyone having to know what snapping is.
    public var fixedGrid: Float? { self == .easy ? 1 : nil }
    public var fixedAngle: Float? { self == .easy ? 90 : nil }

    /// The tool to change to when the one in hand is put away.
    public func tool(replacing current: EditorDocument.Tool) -> EditorDocument.Tool {
        allows(current) ? current : .select
    }

    public init(stored: String?) {
        self = stored.flatMap(StudioLevel.init(rawValue:)) ?? Self.standard
    }
}
