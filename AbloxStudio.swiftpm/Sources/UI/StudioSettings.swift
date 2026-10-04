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
        // Shares the client's key, so setting the language in one app
        // sets it in the other on the same iPad.
        static let language = "ablox.language"
        static let catalogue = "ablox.catalogueRepository"
        static let catalogueBranch = "ablox.catalogueBranch"
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

    /// English, Japanese, or whatever the iPad is set to.
    ///
    /// Applying it writes a global that every `L(...)` reads, including the
    /// ones in `EditorCore` that have no SwiftUI to reach into. SwiftUI does
    /// not observe that global, so `AbloxStudioApp` hangs `.id(language)` on
    /// the view below its state objects.
    @Published public var language: LanguagePreference {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            applyLanguage()
        }
    }

    /// Pushes the current preference into the global the whole app reads.
    public func applyLanguage() {
        Localization.language = language.language(preferredCodes: Locale.preferredLanguages)
    }

    /// Which GitHub repository the published game list lives in.
    ///
    /// Shares the client's key, so a school that points Ablox at its own list
    /// only has to say so once. Studio uses it for the "open the repository"
    /// link on the publish sheet and for opening a published world to edit.
    @Published public var catalogueRepository: String {
        didSet { defaults.set(catalogueRepository, forKey: Key.catalogue) }
    }

    /// The list's branch, shared with the client in the same way.
    @Published public var catalogueBranch: String {
        didSet { defaults.set(catalogueBranch, forKey: Key.catalogueBranch) }
    }

    public var catalogueSource: CatalogueSource {
        CatalogueSource.chosen(repository: catalogueRepository, branch: catalogueBranch)
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

        // Nothing saved means a first launch, which should look like the rest
        // of the iPad rather than like an American default.
        self.language = defaults.string(forKey: Key.language)
            .flatMap(LanguagePreference.init(rawValue:)) ?? .system

        self.catalogueRepository = defaults.string(forKey: Key.catalogue)
            ?? CatalogueSource.default.repository
        self.catalogueBranch = defaults.string(forKey: Key.catalogueBranch)
            ?? CatalogueSource.default.reference

        // Shares the key the client uses, so both apps on one iPad present the
        // same builder.
        if let stored = defaults.string(forKey: Key.peerID), let uuid = UUID(uuidString: stored) {
            self.peerID = PeerID(uuid)
        } else {
            let fresh = PeerID()
            defaults.set(fresh.raw.uuidString, forKey: Key.peerID)
            self.peerID = fresh
        }

        // Before anything reads a string: `didSet` does not run during init.
        applyLanguage()

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
