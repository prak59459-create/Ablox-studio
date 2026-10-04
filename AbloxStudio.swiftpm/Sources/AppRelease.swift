import Foundation

/// This app's version, and where new ones come from.
///
/// `scripts/release.sh` changes the version here, in `Package.swift` and in
/// `update.json` at the top of the repository together, and CI checks that
/// the three agree — a release where they did not would either never be
/// offered or be offered forever.
enum AppRelease {
    static let version = "3.9"
    static let build = 30

    static let current = InstalledApp(
        app: "Ablox Studio",
        version: version,
        build: build,
        package: "AbloxStudio.swiftpm",
        channel: UpdateChannel(owner: "prak59459-create", repository: "Ablox-studio")
    )
}
