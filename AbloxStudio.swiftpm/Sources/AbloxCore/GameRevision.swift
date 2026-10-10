import Foundation

// Knowing when a downloaded game is out of date.
//
// A game from the list is downloaded once and then played from this iPad,
// so it works with no network. But games in the list get better — new rounds,
// fixes — and a copy kept forever means the player never sees them. So each
// download is stamped with the listing it came from, and a listing that says
// something different (another date, size, block count, world or set of
// scripts) means the copy is old and is downloaded again before playing.

extension GameListing {
    /// A short fingerprint of what the list says this version of the game
    /// is. It changes whenever the list's description of the download does.
    public var revision: String {
        var text = "\(Int(updatedAt.timeIntervalSince1970))|\(bytes ?? -1)|\(blockCount)|\(schemaVersion)|\(world)"
        for script in scripts ?? [] {
            text += "|\(script)"
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

public enum GameRevision {
    /// Whether a downloaded copy stamped `stamp` is still the one the list
    /// offers. A copy with no stamp came from a build that did not keep
    /// one, so nobody knows which version it is: it counts as old.
    public static func isCurrent(stamp: String?, for listing: GameListing) -> Bool {
        guard let stamp else { return false }
        return stamp.trimmingCharacters(in: .whitespacesAndNewlines) == listing.revision
    }
}
