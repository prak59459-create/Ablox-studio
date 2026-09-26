import Foundation

/// Everything that is yours on this iPad, in one file: your avatar, your
/// coins and what you bought, every game's saved progress, and your worlds.
///
/// Written from Settings and shared like any file — to Files, AirDrop, a
/// teacher's Mac — so a new or reset iPad can get it all back. Reading one
/// merges rather than replaces: nothing already on the iPad is lost to an
/// older backup.
public struct AbloxBackup: Codable, Sendable {

    public static let fileExtension = "abloxbackup"
    public static let currentVersion = 1
    /// Far above any real backup; a file bigger than this is not one.
    public static let maximumBytes = 200 * 1024 * 1024

    public var version: Int
    public var createdAt: Date
    public var profile: AvatarProfile
    public var wallet: PlayerWallet
    public var saves: [GameSaveStore.Record]
    public var worlds: [WorldDocument]

    public init(createdAt: Date = Date(), profile: AvatarProfile, wallet: PlayerWallet,
                saves: [GameSaveStore.Record], worlds: [WorldDocument]) {
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.profile = profile
        self.wallet = wallet
        self.saves = saves
        self.worlds = worlds
    }

    public enum ReadError: LocalizedError, Equatable {
        case tooBig
        case notABackup
        case newerVersion

        public var errorDescription: String? {
            switch self {
            case .tooBig: return L("That file is too big to be an Ablox backup.")
            case .notABackup: return L("That file is not an Ablox backup.")
            case .newerVersion: return L("That backup was made by a newer Ablox. Update this iPad first.")
            }
        }
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> AbloxBackup {
        guard data.count <= maximumBytes else { throw ReadError.tooBig }
        guard let backup = try? decoder.decode(AbloxBackup.self, from: data) else { throw ReadError.notABackup }
        guard backup.version <= currentVersion else { throw ReadError.newerVersion }
        return backup
    }

    /// `Ablox Backup 2026-09-25.abloxbackup`
    public static func suggestedFileName(on date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Ablox Backup \(formatter.string(from: date)).\(fileExtension)"
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public extension PlayerWallet {
    /// Combines a wallet from a backup with this one without ever lowering
    /// anything: the larger balance, every item either one owns.
    ///
    /// Taking the larger rather than adding means restoring the same backup
    /// twice cannot double anyone's coins.
    func merged(with other: PlayerWallet) -> PlayerWallet {
        PlayerWallet(coins: Swift.max(coins, other.coins),
                     ownedItemIDs: ownedItemIDs.union(other.ownedItemIDs),
                     lifetimeEarned: Swift.max(lifetimeEarned, other.lifetimeEarned))
    }
}
