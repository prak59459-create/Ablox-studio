import Foundation

/// The shape of a room code: which characters exist, how one is cleaned up,
/// and how it is typed on Ablox's own code pad.
///
/// Split out of `RoomCode` (which generates codes with the Security framework,
/// and so lives with the networking) because none of this needs Apple — and
/// the code pad built on it is the fix for a device bug, so it should be
/// tested rather than trusted.
///
/// ## The code pad
///
/// On some iPads the system keyboard never appeared in the join sheet. Two
/// causes, both outside the app's control once they happen:
///
/// - the field asked for focus while the sheet was still animating in, and
///   on slower devices that request is silently dropped;
/// - an iPad with a keyboard case attached never shows the on-screen keyboard
///   at all, even when the case is folded back out of reach.
///
/// The first is fixed by asking later. The second cannot be fixed by asking at
/// all — so the join sheet has its own pad with exactly the thirty characters
/// a code can contain. It works on every device, with or without a keyboard
/// case, and it cannot produce a character that is not in a code.
public enum RoomCodeFormat {

    /// Crockford-style: no I, L, O, U, 0 or 1, so a code read aloud or
    /// squinted at across a table cannot be mistyped into another valid one.
    public static let alphabet: [Character] = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")

    public static let length = 6

    /// Uppercases and strips anything outside the alphabet, so "abcd ef",
    /// "ABCD-EF" and "abcdef" are the same code.
    public static func normalize(_ raw: String) -> String {
        String(raw.uppercased().filter { alphabet.contains($0) })
    }

    public static func isPlausible(_ raw: String) -> Bool {
        normalize(raw).count >= 4
    }

    /// Groups a code for display: `ABC DEF`.
    public static func formatted(_ raw: String) -> String {
        let normalized = normalize(raw)
        guard normalized.count > 4 else { return normalized }
        let mid = normalized.index(normalized.startIndex, offsetBy: normalized.count / 2)
        return "\(normalized[..<mid]) \(normalized[mid...])"
    }

    // MARK: The pad

    /// The keys, in rows, as the pad lays them out.
    ///
    /// Letters first in alphabetical order, then digits — the order someone
    /// hunting for a character expects. Six to a row, which is the code length,
    /// so the pad reads as a grid rather than a keyboard.
    public static var padRows: [[Character]] {
        stride(from: 0, to: alphabet.count, by: 6).map { start in
            Array(alphabet[start..<Swift.min(start + 6, alphabet.count)])
        }
    }

    /// A key press, applied to the code typed so far.
    ///
    /// Works on the normalised code, so a field that also accepts a hardware
    /// keyboard — which can type anything — and the pad never disagree about
    /// what has been entered.
    public static func typing(_ key: Character, into code: String) -> String {
        let current = normalize(code)
        guard alphabet.contains(key), current.count < length else { return current }
        return current + String(key)
    }

    public static func deleting(from code: String) -> String {
        String(normalize(code).dropLast())
    }

    /// Characters a code never contains, named on the pad so someone who
    /// thinks they see one knows they have misread rather than searching for a
    /// key that is not there.
    ///
    /// All six are left out *together* — an earlier version of the hint said
    /// "type 0 or 1 instead of O or I", which sent people looking for keys the
    /// pad does not have either. `RoomCodeFormatTests` holds the hint to the
    /// alphabet now.
    public static let neverUsed: [Character] = ["O", "0", "I", "1", "L", "U"]
}
