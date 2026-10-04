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
/// With the project on this iPad chosen once, a new version instead goes
/// straight into it, only the files that changed (`ProjectSync`), so Swift
/// Playgrounds rebuilds those rather than the whole app — by itself as soon
/// as it is downloaded, or with one tap (`updateNow`). Swift Playgrounds keeps
/// an open project as it was when opened, so the new files count once the
/// project is closed and opened again; the next launch checks that they did
/// (`waitingForReopen`).
///
/// Downloads try again by themselves when the connection drops or GitHub is
/// busy, and from a second address (`UpdateRetry`, `UpdateChannel`); what
/// still goes wrong is written to the problem reports with its error code.
///
/// The rules — what is newer, what a manifest may say, which files are the
/// project — are in `AppUpdate.swift` and `ProjectSync.swift` in the core,
/// where they are tested. This is the networking and the files.
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

    /// Putting a new version straight into the project on this iPad.
    public enum InPlace: Equatable {
        case idle
        case working
        /// Files written and deleted; both 0 when it was already the same.
        case done(written: Int, deleted: Int)
        case failed(String)
    }

    @Published public private(set) var inPlace: InPlace = .idle
    /// The project chosen in Files ("Ablox.swiftpm"), once there is one.
    @Published public private(set) var linkedProject: String?
    /// Put a downloaded version straight into the chosen project without
    /// being asked.
    @Published public var installsAutomatically: Bool {
        didSet { defaults.set(installsAutomatically, forKey: Keys.autoInstall) }
    }
    /// The version written into the project ("2.1-10") that is not running
    /// yet: Swift Playgrounds builds it once the project is opened again.
    @Published public private(set) var waitingForReopen: String?
    /// True when the app was opened again after writing a version into the
    /// project, and it is still the old one: the project was not reopened.
    @Published public private(set) var stillOld = false
    /// A branch to take versions from instead of the released ones, for
    /// trying something before it is out. Empty: the released ones.
    @Published public var followedBranch: String {
        didSet { defaults.set(followedBranch, forKey: Keys.branch) }
    }

    /// Where versions come from: the release channel, or the followed
    /// branch of the same repository.
    public var channel: UpdateChannel {
        let branch = followedBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return release.channel }
        return UpdateChannel(owner: release.channel.owner, repository: release.channel.repository, branch: branch)
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
        static let project = "update.project"
        static let projectInside = "update.projectInside"
        static let branch = "update.branch"
        static let autoInstall = "update.autoInstall"
        static let written = "update.written"
    }

    public init(release: InstalledApp, defaults: UserDefaults = .standard) {
        self.release = release
        self.defaults = defaults
        checksAutomatically = defaults.object(forKey: Keys.autoCheck) as? Bool ?? true
        downloadsAutomatically = defaults.object(forKey: Keys.autoDownload) as? Bool ?? true
        followedBranch = defaults.string(forKey: Keys.branch) ?? ""
        installsAutomatically = defaults.object(forKey: Keys.autoInstall) as? Bool ?? true
        if defaults.data(forKey: Keys.project) != nil {
            linkedProject = defaults.string(forKey: Keys.projectInside).flatMap { $0.isEmpty ? nil : $0 } ?? release.package
        }
        if let seconds = defaults.object(forKey: Keys.lastChecked) as? Double {
            lastChecked = Date(timeIntervalSince1970: seconds)
        }
        if let data = defaults.data(forKey: Keys.latest),
           let manifest = try? UpdateManifest.decode(data, forApp: release.app) {
            latest = manifest
            availability = UpdatePolicy.availability(installed: release.version, build: release.build, manifest: manifest)
        }
        noticeNewVersion()
        // A version written into the project earlier: running now, or still
        // waiting for the project to be opened again?
        if let written = defaults.string(forKey: Keys.written) {
            if written == "\(release.version)-\(release.build)" || !Self.isNewer(written, than: release) {
                defaults.removeObject(forKey: Keys.written)
            } else {
                waitingForReopen = written
                stillOld = true
            }
        }
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
        guard !isBusy, let url = channel.manifestURL else { return }
        let before = phase
        phase = .checking
        do {
            let data = try await withRetries { () async throws -> Data in
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                let (data, response) = try await URLSession.shared.data(for: request)
                try Self.checkStatus(response)
                return data
            }
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
            // Either way it goes in the problem reports, with its code.
            note("check", error)
            phase = userInitiated ? .failed(Self.message(for: error)) : (before == .checking ? .idle : before)
        }
    }

    // MARK: Downloading

    public func download(automatic: Bool = false) async {
        guard let manifest = latest, phase != .downloading, phase != .unpacking else { return }
        phase = .downloading
        do {
            let data = try await fetchArchive(automatic: automatic)
            phase = .unpacking
            stagedPackage = try await unpack(data, into: stagingFolder(for: manifest))
            defaults.set(Self.label(manifest), forKey: Keys.staged)
            phase = .ready
        } catch {
            note("download", error)
            phase = automatic ? .available : .failed(Self.message(for: error))
            return
        }
        // With the project chosen, nothing is left for anyone to do.
        if installsAutomatically, linkedProject != nil {
            await installInPlace()
        }
    }

    /// The one tap: download if that is still to do, then put it into the
    /// chosen project. Without a chosen project it stops at downloaded, and
    /// the install sheet says how to choose one.
    public func updateNow() async {
        if case .newer = availability, stagedPackage == nil {
            // Puts it in by itself when it may, so once is enough.
            await download()
            if installsAutomatically { return }
        }
        guard stagedPackage != nil, linkedProject != nil, inPlace != .working else { return }
        await installInPlace()
    }

    /// The repository as a zip, checked for size: each address in turn, each
    /// with a few tries.
    private func fetchArchive(automatic: Bool) async throws -> Data {
        let urls = channel.archiveURLs
        guard !urls.isEmpty else { throw Failure.status(0) }
        var last: Error = Failure.status(0)
        for url in urls {
            do {
                return try await withRetries { () async throws -> Data in try await self.fetch(url, automatic: automatic) }
            } catch {
                last = error
            }
        }
        throw last
    }

    private func fetch(_ url: URL, automatic: Bool) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        if automatic {
            // Not on a phone's data plan or in Low Data Mode without asking.
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.checkStatus(response)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= UpdatePackage.Limits.maximumBytes else { throw Failure.tooLarge }
        return try Data(contentsOf: file)
    }

    /// Runs `work`, trying again after a pause when the failure is the kind
    /// that passes (`UpdateRetry`): a dropped connection, a busy server.
    private func withRetries<T>(_ work: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch {
                guard attempt < UpdateRetry.delays.count, Self.isTemporary(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(UpdateRetry.delays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    nonisolated private static func checkStatus(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.status(status) }
    }

    private static func isTemporary(_ error: Error) -> Bool {
        if case let .status(code)? = error as? Failure { return UpdateRetry.isTemporary(status: code) }
        if let error = error as? URLError { return UpdateRetry.isTemporary(urlErrorCode: error.code.rawValue) }
        return false
    }

    /// The project folder out of the zip, checked, written to `folder`.
    private func unpack(_ data: Data, into folder: URL) async throws -> URL {
        let package = release.package
        // Unzipping a few megabytes is real work: off the main thread.
        return try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let archive = try ZipArchive(data)
            let project = try UpdatePackage(archive: archive, package: package)
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try project.write(into: folder.deletingLastPathComponent())
            return folder
        }.value
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

    // MARK: Straight into the project on this iPad

    /// Remembers the project chosen in Files: its folder, or the
    /// Playgrounds folder it is in. Returns what was wrong, if anything.
    public func linkProject(at picked: URL) -> String? {
        let access = picked.startAccessingSecurityScopedResource()
        defer { if access { picked.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        var inside = ""
        if !manager.fileExists(atPath: picked.appendingPathComponent(ProjectSync.manifest).path) {
            let child = picked.appendingPathComponent(release.package, isDirectory: true)
            guard manager.fileExists(atPath: child.appendingPathComponent(ProjectSync.manifest).path) else {
                return L("That is not the project. In Files, choose {} in the Playgrounds folder.", release.package)
            }
            inside = release.package
        }
        let project = inside.isEmpty ? picked : picked.appendingPathComponent(inside, isDirectory: true)
        if let manifest = try? String(contentsOf: project.appendingPathComponent(ProjectSync.manifest), encoding: .utf8),
           let staged = stagedPackage.flatMap({ try? String(contentsOf: $0.appendingPathComponent(ProjectSync.manifest), encoding: .utf8) }),
           ProjectSync.bundleIdentifier(inManifest: manifest) != ProjectSync.bundleIdentifier(inManifest: staged) {
            return L("That project is a different app. Choose {} in the Playgrounds folder.", release.package)
        }
        guard let bookmark = try? picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return L("That folder could not be remembered. Choose it again.")
        }
        defaults.set(bookmark, forKey: Keys.project)
        defaults.set(inside, forKey: Keys.projectInside)
        linkedProject = project.lastPathComponent
        inPlace = .idle
        return nil
    }

    public func unlinkProject() {
        defaults.removeObject(forKey: Keys.project)
        defaults.removeObject(forKey: Keys.projectInside)
        linkedProject = nil
        inPlace = .idle
    }

    /// Writes the downloaded version into the project on this iPad, only
    /// the files that changed.
    public func installInPlace() async {
        guard let staged = stagedPackage else { return }
        await putInPlace(staged, version: latest.map(Self.label))
    }

    /// The followed branch (or the released version) as it is right now,
    /// straight into the project, whatever its version number says: for
    /// trying something before it is released.
    public func pullLatest() async {
        guard linkedProject != nil, inPlace != .working else { return }
        inPlace = .working
        do {
            let data = try await fetchArchive(automatic: false)
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            let folder = caches.appendingPathComponent("Update", isDirectory: true)
                .appendingPathComponent("latest", isDirectory: true)
                .appendingPathComponent(release.package, isDirectory: true)
            let staged = try await unpack(data, into: folder)
            await putInPlace(staged, alreadyWorking: true)
        } catch {
            note("pull", error)
            inPlace = .failed(Self.message(for: error))
        }
    }

    /// Writes `staged` into the chosen project. `version` is the released
    /// version it is ("2.1-10"), remembered so the next launch can tell
    /// whether the project was opened again.
    private func putInPlace(_ staged: URL, alreadyWorking: Bool = false, version: String? = nil) async {
        guard alreadyWorking || inPlace != .working else { return }
        guard let data = defaults.data(forKey: Keys.project) else {
            inPlace = .failed(L("Choose the project first."))
            return
        }
        inPlace = .working
        var stale = false
        guard let scope = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            inPlace = .failed(L("The project could not be found. Choose it again."))
            return
        }
        let inside = defaults.string(forKey: Keys.projectInside) ?? ""
        let project = inside.isEmpty ? scope : scope.appendingPathComponent(inside, isDirectory: true)
        let outcome: Result<ProjectSync.Plan, Error> = await Task.detached(priority: .userInitiated) {
            let access = scope.startAccessingSecurityScopedResource()
            defer { if access { scope.stopAccessingSecurityScopedResource() } }
            return Result { try Self.sync(from: staged, into: project) }
        }.value
        if stale, scope.startAccessingSecurityScopedResource() {
            if let fresh = try? scope.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Keys.project)
            }
            scope.stopAccessingSecurityScopedResource()
        }
        switch outcome {
        case let .success(plan):
            inPlace = .done(written: plan.writes.count, deleted: plan.deletions.count)
            if let version, !plan.writes.isEmpty || !plan.deletions.isEmpty {
                defaults.set(version, forKey: Keys.written)
                waitingForReopen = version
                stillOld = false
            }
        case let .failure(error):
            note("write", error)
            inPlace = .failed(inPlaceMessage(for: error))
        }
    }

    /// Reads both projects, works out the difference and writes it, all
    /// under file coordination: Swift Playgrounds sees the change the way
    /// it sees one arriving from iCloud.
    nonisolated private static func sync(from staged: URL, into project: URL) throws -> ProjectSync.Plan {
        let new = try files(in: staged)
        var coordination: NSError?
        var outcome: Result<ProjectSync.Plan, Error> = .failure(ProjectSync.Problem.notAProject)
        NSFileCoordinator().coordinate(writingItemAt: project, options: [], error: &coordination) { folder in
            outcome = Result {
                let plan = try ProjectSync.plan(new: new, current: try files(in: folder))
                let manager = FileManager.default
                for (path, bytes) in plan.writes {
                    let url = folder.appendingPathComponent(path)
                    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(bytes).write(to: url, options: .atomic)
                }
                for path in plan.deletions {
                    try? manager.removeItem(at: folder.appendingPathComponent(path))
                    removeEmptyFolders(above: path, in: folder)
                }
                // Read back what was written: a folder that only looked
                // writable is caught here, not at the next build.
                for (path, bytes) in plan.writes {
                    guard let written = manager.contents(atPath: folder.appendingPathComponent(path).path), [UInt8](written) == bytes else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                return plan
            }
        }
        if let coordination { throw coordination }
        return try outcome.get()
    }

    /// `Package.swift` and every file under `Sources/`, as path → bytes.
    /// A file that cannot be read is left out, so it is written again.
    nonisolated private static func files(in package: URL) throws -> [String: [UInt8]] {
        let manager = FileManager.default
        var result: [String: [UInt8]] = [:]
        if let data = manager.contents(atPath: package.appendingPathComponent(ProjectSync.manifest).path) {
            result[ProjectSync.manifest] = [UInt8](data)
        }
        let sources = package.appendingPathComponent("Sources", isDirectory: true)
        let base = sources.resolvingSymlinksInPath().pathComponents
        guard let walker = manager.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let parts = url.resolvingSymlinksInPath().pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
            guard result.count < UpdatePackage.Limits.maximumFiles else { throw UpdatePackage.Problem.tooLarge }
            let path = (["Sources"] + parts.dropFirst(base.count)).joined(separator: "/")
            if let data = manager.contents(atPath: url.path) { result[path] = [UInt8](data) }
        }
        return result
    }

    /// After a deletion, the folders it leaves empty, up to `Sources`.
    nonisolated private static func removeEmptyFolders(above path: String, in package: URL) {
        let manager = FileManager.default
        var folder = (path as NSString).deletingLastPathComponent
        while folder.hasPrefix("Sources/") {
            let url = package.appendingPathComponent(folder, isDirectory: true)
            guard let contents = try? manager.contentsOfDirectory(atPath: url.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            try? manager.removeItem(at: url)
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    private func inPlaceMessage(for error: Error) -> String {
        switch error as? ProjectSync.Problem {
        case .notAProject?:
            return L("The chosen folder is not the project any more. Choose it again.")
        case .otherApp?:
            return L("That project is a different app. Choose {} in the Playgrounds folder.", release.package)
        case nil:
            if (error as NSError).domain == NSCocoaErrorDomain {
                return L("The project's folder could not be written to. Choose it again in Files.")
            }
            return Self.message(for: error)
        }
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
        defaults.removeObject(forKey: Keys.written)
    }

    /// Whether "2.1-10" is a later version than the one running.
    private static func isNewer(_ label: String, than release: InstalledApp) -> Bool {
        let parts = label.split(separator: "-")
        guard let version = parts.first.flatMap({ AppVersion(String($0)) }) else { return false }
        let build = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return version > release.version || (version == release.version && build > release.build)
    }

    /// The new version is in the project, and the player has seen how to
    /// open it: stop reminding until the next launch says otherwise.
    public func dismissReopenReminder() {
        stillOld = false
    }

    // MARK: Errors

    private enum Failure: Error, Equatable {
        /// GitHub answered with this HTTP status (0: no answer at all).
        case status(Int)
        case tooLarge
    }

    /// Writes what went wrong, with its code, into the problem reports, so
    /// "copy the report" says exactly which step failed and why.
    private func note(_ step: String, _ error: Error) {
        let detail: String
        if case let .status(code)? = error as? Failure {
            detail = UpdateRetry.technicalDetail(domain: "HTTP", code: code, step: step)
        } else {
            let ns = error as NSError
            detail = UpdateRetry.technicalDetail(domain: ns.domain, code: ns.code, step: step)
        }
        ProblemRecorder.shared.record(.update, Self.message(for: error), detail: detail)
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? Failure {
            if case .tooLarge = failure { return L("That download was too big and was refused.") }
            return L("GitHub did not answer properly. Try again in a few minutes.")
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
