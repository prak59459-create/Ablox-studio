import Foundation
import Combine

/// Studio's persisted preferences and device identity.
///
/// Intentionally smaller than the client's `AppSettings`: the editor has no
/// joystick, no camera sensitivity and no movement tuning to remember. What it
/// does share is the peer identity and the avatar, so a person appears as the
/// same builder whether they are editing or playing.
@MainActor
public final class StudioSettings: ObservableObject {

    private enum Key {
        static let profile = "ablox.profile"
        static let peerID = "ablox.peerID"
        static let gridSize = "ablox.studio.gridSize"
        static let angleSnap = "ablox.studio.angleSnap"
    }

    private let defaults: UserDefaults

    @Published public var profile: AvatarProfile {
        didSet {
            guard let data = try? JSONEncoder().encode(profile) else { return }
            defaults.set(data, forKey: Key.profile)
        }
    }

    /// Remembered so the snap settings survive closing a project.
    @Published public var gridSize: Float {
        didSet { defaults.set(Double(gridSize), forKey: Key.gridSize) }
    }

    @Published public var angleSnap: Float {
        didSet { defaults.set(Double(angleSnap), forKey: Key.angleSnap) }
    }

    public let peerID: PeerID

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Key.profile),
           let stored = try? JSONDecoder().decode(AvatarProfile.self, from: data) {
            self.profile = stored
        } else {
            self.profile = .default
        }

        self.gridSize = Float(defaults.object(forKey: Key.gridSize) as? Double ?? 0.5)
        self.angleSnap = Float(defaults.object(forKey: Key.angleSnap) as? Double ?? 15)

        // Shares the key the client uses, so both apps on one iPad present the
        // same builder.
        if let stored = defaults.string(forKey: Key.peerID), let uuid = UUID(uuidString: stored) {
            self.peerID = PeerID(uuid)
        } else {
            let fresh = PeerID()
            defaults.set(fresh.raw.uuidString, forKey: Key.peerID)
            self.peerID = fresh
        }

        if profile.displayName.isEmpty || profile == .default {
            var generated = AvatarProfile.generated(for: peerID, name: Self.suggestedName())
            generated.displayName = Self.suggestedName()
            self.profile = generated
        }
    }

    private static func suggestedName() -> String {
        #if canImport(UIKit)
        let deviceName = UIDevice.current.name
        if let cut = deviceName.range(of: "'s ") {
            return String(deviceName[..<cut.lowerBound])
        }
        if !deviceName.isEmpty, deviceName != "iPad" { return deviceName }
        #endif
        return "Builder"
    }
}

#if canImport(UIKit)
import UIKit
#endif
