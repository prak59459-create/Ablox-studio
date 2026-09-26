import Foundation
import Combine

/// Keeps this app up to date by itself, as far as an iPad allows.
///
/// On launch, and every few hours after, it reads the repository's
/// `update.json`. When there is a newer version it downloads the repository,
/// unpacks the project folder and checks every file, all without being asked
/// (on Wi-Fi, outside Low Data Mode). Then one tap hands the new project to
/// Swift Playgrounds. After the new version starts, it says once what
/// changed.
///
/// The rules — what is newer, what a manifest may say, which files are the
/// project — are in `AppUpdate.swift` in the core, where they are tested.
/// This is the networking and the files.
@MainActor
public final class AppUpdater: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// Newer, not downloaded yet.
        case available
        case downloading
        case unpacking
        /// Downloaded and unpacked: `stagedPackage` is ready to hand over.
        case ready
        case failed(String)
    }

    public let release: InstalledApp

    @Published public private(set) var phase: Phase = .idle
    /// The newest manifest seen, kept between launches.
    @Published public private(set) var latest: UpdateManifest?
    @Published public private(set) var availability: UpdateAvailability = .current
    /// The new project folder, unpacked and checked.
    @Published public private(set) var stagedPackage: URL?
    @Published public private(set) var lastChecked: Date?
    /// Set on the first launch of a new version: what changed, once.
    @Published public var justUpdated: UpdateManifest?

    @Published public var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Keys.autoCheck) }
    }
    @Published public var downloadsAutomatically: Bool {
        didSet { defaults.set(downloadsAutomatically, forKey: Keys.autoDownload) }
    }

    private let defaults: UserDefaults
    private var timer: AnyCancellable?

    private enum Keys {
        static let autoCheck = "update.autoCheck"
        static let autoDownload = "update.autoDownload"
        static let lastChecked = "update.lastChecked"
        static let latest = "update.latest"
        static let skipped = "update.skipped"
        static let staged = "update.staged"
        static let lastRun = "update.lastRun"
    }

    public init(release: InstalledApp, defaults: UserDefaults = .standard) {
        self.release = release
        self.defaults = defaults
        checksAutomatically = defaults.object(forKey: Keys.autoCheck) as? Bool ?? true
        downloadsAutomatically = defaults.object(forKey: Keys.autoDownload) as? Bool ?? true
        if let seconds = defaults.object(forKey: Keys.lastChecked) as? Double {
            lastChecked = Date(timeIntervalSince1970: seconds)
        }
        if let data = defaults.data(forKey: Keys.latest),
           let manifest = try? UpdateManifest.decode(data, forApp: release.app) {
            latest = manifest
            availability = UpdatePolicy.availability(installed: release.version, build: release.build, manifest: manifest)
        }
        noticeNewVersion()
        // A project unpacked before this launch is still there unless the
        // system cleared the cache.
        if case .newer = availability, let staged = defaults.string(forKey: Keys.staged),
           staged == latest.map(Self.label), FileManager.default.fileExists(atPath: stagingFolder(for: latest!).path) {
            stagedPackage = stagingFolder(for: latest!)
            phase = .ready
        } else if case .newer = availability {
            phase = .available
        }
    }

    // MARK: Launch and after

    /// Checks now if it is time to, then every hour while the app is open
    /// (each of which only looks if the interval has passed).
    public func start() {
        guard timer == nil else { return }
        Task { await checkIfDue() }
        timer = Timer.publish(every: 3600, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { await self?.checkIfDue() }
        }
    }

    public func checkIfDue() async {
        guard checksAutomatically, UpdatePolicy.isDue(lastCheck: lastChecked) else { return }
        await check(userInitiated: false)
    }

    /// The version the player chose not to install now: not offered again
    /// until something newer (or required) comes.
    public func skipLatest() {
        guard let latest else { return }
        defaults.set(latest.version.description, forKey: Keys.skipped)
        objectWillChange.send()
    }

    /// Whether to show the update in the menu without being asked.
    public var shouldOffer: Bool {
        guard let latest else { return false }
        let skipped = defaults.string(forKey: Keys.skipped).flatMap(AppVersion.init)
        return UpdatePolicy.shouldOffer(latest, availability: availability, skipped: skipped)
    }

    public var isRequired: Bool {
        if case .newer(required: true) = availability { return true }
        return false
    }

    public var isBusy: Bool {
        phase == .checking || phase == .downloading || phase == .unpacking
    }

    // MARK: Checking

    public func check(userInitiated: Bool = true) async {
        guard !isBusy, let url = release.channel.manifestURL else { return }
        let before = phase
        phase = .checking
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.server }
            let manifest = try UpdateManifest.decode(data, forApp: release.app)
            lastChecked = Date()
            defaults.set(lastChecked!.timeIntervalSince1970, forKey: Keys.lastChecked)
            latest = manifest
            defaults.set(data, forKey: Keys.latest)
            availability = UpdatePolicy.availability(installed: release.version, build: release.build, manifest: manifest)

            guard case .newer = availability else {
                phase = .upToDate
                return
            }
            if let staged = stagedPackage, defaults.string(forKey: Keys.staged) == Self.label(manifest),
               FileManager.default.fileExists(atPath: staged.path) {
                phase = .ready
                return
            }
            stagedPackage = nil
            phase = .available
            if downloadsAutomatically, shouldOffer || userInitiated {
                await download(automatic: !userInitiated)
            }
        } catch {
            // A check nobody asked for fails quietly; the next one will do.
            phase = userInitiated ? .failed(Self.message(for: error)) : (before == .checking ? .idle : before)
        }
    }

    // MARK: Downloading

    public func download(automatic: Bool = false) async {
        guard let manifest = latest, let url = release.channel.archiveURL,
              phase != .downloading, phase != .unpacking else { return }
        phase = .downloading
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
            if automatic {
                // Not on a phone's data plan or in Low Data Mode without asking.
                request.allowsExpensiveNetworkAccess = false
                request.allowsConstrainedNetworkAccess = false
            }
            let (file, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.server }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            guard size <= UpdatePackage.Limits.maximumBytes else { throw Failure.tooLarge }
            let data = try Data(contentsOf: file)

            phase = .unpacking
            let folder = stagingFolder(for: manifest)
            let package = release.package
            // Unzipping a few megabytes is real work: off the main thread.
            let staged = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                let archive = try ZipArchive(data)
                let project = try UpdatePackage(archive: archive, package: package)
                try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
                try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                try project.write(into: folder.deletingLastPathComponent())
                return folder
            }.value
            stagedPackage = staged
            defaults.set(Self.label(manifest), forKey: Keys.staged)
            phase = .ready
        } catch {
            phase = automatic ? .available : .failed(Self.message(for: error))
        }
    }

    /// Caches/Update/<version>/<Package>.swiftpm — the folder name has to be
    /// the project's own, or Swift Playgrounds shows it under another name.
    private func stagingFolder(for manifest: UpdateManifest) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Update", isDirectory: true)
            .appendingPathComponent(Self.label(manifest), isDirectory: true)
            .appendingPathComponent(release.package, isDirectory: true)
    }

    private static func label(_ manifest: UpdateManifest) -> String {
        "\(manifest.version)-\(manifest.build)"
    }

    // MARK: After updating

    /// The first launch of a newer version than last time: remember it, and
    /// say what changed (from the manifest the old version downloaded).
    private func noticeNewVersion() {
        let current = "\(release.version)-\(release.build)"
        let previous = defaults.string(forKey: Keys.lastRun)
        defaults.set(current, forKey: Keys.lastRun)
        guard let previous, previous != current else { return }
        let parts = previous.split(separator: "-")
        let oldVersion = parts.first.flatMap { AppVersion(String($0)) } ?? AppVersion("0")!
        let oldBuild = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        guard release.version > oldVersion || (release.version == oldVersion && release.build > oldBuild) else { return }
        justUpdated = latest.flatMap { $0.version == release.version ? $0 : nil }
            ?? UpdateManifest(app: release.app, version: release.version, build: release.build, protocolVersion: AbloxProtocol.version,
                              date: "", package: release.package, notes: [:])
        // The downloaded copy has done its job.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let update = caches?.appendingPathComponent("Update", isDirectory: true) { try? FileManager.default.removeItem(at: update) }
        defaults.removeObject(forKey: Keys.staged)
        defaults.removeObject(forKey: Keys.skipped)
    }

    // MARK: Errors

    private enum Failure: Error {
        case server
        case tooLarge
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? Failure {
            return failure == .server
                ? L("GitHub did not answer properly. Try again in a few minutes.")
                : L("That download was too big and was refused.")
        }
        if let problem = error as? UpdatePackage.Problem, problem == .tooLarge {
            return L("That download was too big and was refused.")
        }
        if error is UpdateManifest.Problem || error is UpdatePackage.Problem || error is ZipArchive.Failure {
            return L("The new version could not be read. Try again later.")
        }
        if let error = error as? URLError, error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            return L("This iPad is not connected to the internet.")
        }
        return L("Could not reach GitHub.")
    }
}
