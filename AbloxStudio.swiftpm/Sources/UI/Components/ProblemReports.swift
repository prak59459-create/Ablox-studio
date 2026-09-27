import SwiftUI
import UIKit
import Darwin

/// Keeps the problems this iPad has had — script errors, a room that could
/// not be reached, a world that would not save, a crash — so they can be
/// copied into a message in one tap and sent to whoever is helping.
///
/// A crash cannot be written down properly while it is happening, so two
/// small things are left behind instead: a file that says the app is running
/// (removed when it goes to the background), and a line the signal handler
/// writes as the app goes down. The next launch reads both, together with
/// what the player was last doing.
@MainActor
public final class ProblemRecorder: ObservableObject {

    public static let shared = ProblemRecorder()

    @Published public private(set) var log = ProblemLog()

    private let folder: URL
    private var logURL: URL { folder.appendingPathComponent("problems.json") }
    private var runningURL: URL { folder.appendingPathComponent("running") }
    private var crashURL: URL { folder.appendingPathComponent("crash") }
    private static let activityKey = "ablox.problems.activity"
    private var appName = "Ablox"
    private var started = false
    private var saveTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("Problems", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: logURL) { log = ProblemLog.decoded(from: data) }
    }

    /// Once, at launch: notices a last run that ended badly, then starts
    /// watching this one.
    public func start(app: String) {
        guard !started else { return }
        started = true
        appName = app
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: runningURL.path) {
            let marker = (try? String(contentsOf: crashURL, encoding: .utf8)) ?? ""
            let doing = UserDefaults.standard.string(forKey: Self.activityKey)
            record(.crash, CrashMarker.report(signal: CrashMarker.signal(in: marker), doing: doing))
        }
        try? fileManager.removeItem(at: crashURL)
        CrashCatcher.install(path: crashURL.path)
        markRunning(true)
    }

    /// Settings → the app went to the background (true when it came back).
    public func markRunning(_ running: Bool) {
        if running {
            FileManager.default.createFile(atPath: runningURL.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: runningURL)
        }
    }

    /// What the player is doing, remembered in case the app goes down.
    public func noteActivity(_ doing: String) {
        UserDefaults.standard.set(String(doing.prefix(200)), forKey: Self.activityKey)
    }

    public func record(_ area: ProblemReport.Area, _ message: String, detail: String? = nil) {
        log.add(area, message, detail: detail, at: Date().timeIntervalSince1970)
        scheduleSave()
    }

    public func clear() {
        log = ProblemLog()
        scheduleSave()
    }

    /// The text to paste into a message.
    public var reportText: String {
        log.text(app: appName, version: Self.version, device: Self.device, system: Self.system,
                 now: Date().timeIntervalSince1970)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, let data = self.log.encoded() else { return }
            try? data.write(to: self.logURL, options: .atomic)
        }
    }

    // MARK: About this iPad

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// "iPad (iPad12,1)": the model and the exact hardware.
    private static var device: String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(UIDevice.current.model) (\(machine))"
    }

    private static var system: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }
}

/// Writes one prepared line when the app is brought down by a signal, then
/// lets the crash carry on as it would have. Everything the handler touches
/// is made before it is installed: in a signal handler only `write` is safe.
enum CrashCatcher {

    private static var installed = false

    static func install(path: String) {
        guard !installed else { return }
        installed = true
        crashDescriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard crashDescriptor >= 0 else { return }
        for signal in CrashMarker.signals where signal >= 0 && signal < 32 {
            crashLines[Int(signal)] = strdup(CrashMarker.line(for: signal))
            Darwin.signal(signal, abloxCrashHandler)
        }
    }
}

/// Set once by `CrashCatcher.install`, read by the handler.
private var crashDescriptor: Int32 = -1
private let crashLines = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 32).initialized()

private extension UnsafeMutablePointer where Pointee == UnsafeMutablePointer<CChar>? {
    func initialized() -> Self {
        initialize(repeating: nil, count: 32)
        return self
    }
}

private func abloxCrashHandler(_ signal: Int32) {
    if crashDescriptor >= 0, signal >= 0, signal < 32, let line = crashLines[Int(signal)] {
        _ = write(crashDescriptor, line, strlen(line))
    }
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

// MARK: - Settings card

public struct ProblemReportsCard: View {
    @ObservedObject private var recorder = ProblemRecorder.shared
    @State private var copied = false
    @State private var showingAll = false

    public init() {}

    public var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(L("Problem reports"), systemImage: "stethoscope")

                Text(L("Errors and crashes are kept on this iPad. Copy them and paste them into a message to whoever is helping you."))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if recorder.log.reports.isEmpty {
                    Label(L("No problems so far."), systemImage: "checkmark.seal.fill")
                        .font(.subheadline)
                        .foregroundStyle(Ablox.Palette.success)
                } else {
                    ForEach(recorder.log.reports.suffix(3).reversed()) { report in
                        ProblemReportRow(report: report)
                    }
                    if recorder.log.reports.count > 3 {
                        Button(L("See all {}", recorder.log.reports.count)) { showingAll = true }
                            .font(.caption.weight(.semibold))
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = recorder.reportText
                        copied = true
                    } label: {
                        Label(copied ? L("Copied") : L("Copy the report"), systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.primary))

                    ShareLink(item: recorder.reportText) {
                        Label(L("Share"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                }

                if !recorder.log.reports.isEmpty {
                    Button(L("Clear the list"), role: .destructive) { recorder.clear() }
                        .font(.caption)
                }
            }
        }
        .sheet(isPresented: $showingAll) {
            NavigationStack {
                List(recorder.log.reports.reversed()) { report in
                    ProblemReportRow(report: report)
                }
                .navigationTitle(L("Problem reports"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showingAll = false } }
                }
            }
            .abloxColorScheme()
        }
    }
}

private struct ProblemReportRow: View {
    let report: ProblemReport

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.area.symbolName)
                .foregroundStyle(report.area == .crash ? Ablox.Palette.danger : Ablox.Palette.warning)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(report.area.displayName).font(.caption.weight(.bold))
                    if report.count > 1 { Text(verbatim: "×\(report.count)").font(.caption2).foregroundStyle(Ablox.Palette.inkFaint) }
                    Spacer()
                    Text(Date(timeIntervalSince1970: report.time), style: .relative)
                        .font(.caption2)
                        .foregroundStyle(Ablox.Palette.inkFaint)
                }
                if let detail = report.detail {
                    Text(verbatim: detail).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
                }
                Text(verbatim: report.message)
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.ink)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
