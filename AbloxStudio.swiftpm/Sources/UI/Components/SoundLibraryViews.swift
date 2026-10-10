import SwiftUI
import AbloxCore
#if canImport(UIKit)
import UIKit
#endif

// The sound library screen: every sound by category, a search, a tap to
// listen, its name to copy into a script, and "Download every sound" with
// the megabytes so far. Shared with Studio, where `onPick` puts the chosen
// sound into a rule or a script.

/// The whole screen, for a sheet.
public struct SoundLibraryView: View {
    let source: CatalogueSource
    /// Studio: called with the sound chosen. Nil in Ablox, where a sound's
    /// name is copied instead.
    let onPick: ((String) -> Void)?

    @ObservedObject private var store = SoundLibraryStore.shared
    @AppStorage(FeedbackPlayer.recordedCuesKey) private var recordedCues = true
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category: String?
    @State private var open: Set<String> = []
    @State private var copied: String?
    @State private var confirmingDelete = false

    public init(source: CatalogueSource, onPick: ((String) -> Void)? = nil) {
        self.source = source
        self.onPick = onPick
    }

    private var results: [SoundLibrary.Family] {
        store.library?.search(search, category: category) ?? []
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    SoundDownloadAllCard(store: store, category: category)
                    statusLine
                    searchField
                    categoryChips
                    if store.library != nil {
                        let found = results
                        Text(L("{} kinds · {} sounds", found.count, found.reduce(0) { $0 + $1.sounds.count }))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Ablox.Palette.inkFaint)
                        ForEach(found.prefix(400)) { family in
                            SoundFamilyRow(family: family, store: store, isOpen: open.contains(family.id),
                                           copied: copied, onPick: pickAndClose,
                                           toggle: { toggle(family.id) }, copy: copy)
                        }
                    }
                    settingsCard
                    Text(L("Sounds from SFXMint (sfxmint.com). Every one is CC0: free to use in any game, no credit needed."))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .background(Ablox.Palette.background.ignoresSafeArea())
            .navigationTitle(L("Sound library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .refreshable { await store.refresh() }
        }
        .task {
            store.source = source
            await store.refreshIfStale()
        }
        .alert(L("Delete downloaded sounds?"), isPresented: $confirmingDelete) {
            Button(L("Delete"), role: .destructive) { store.removeAll() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("{} on this iPad. A game that plays one downloads it again.", Megabytes.text(store.installedBytes)))
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch store.status {
        case .loading where store.library == nil:
            HStack(spacing: 8) {
                ProgressView()
                Text(L("Getting the sound list…")).font(.subheadline).foregroundStyle(Ablox.Palette.inkMuted)
            }
        case let .offline(message), let .failed(message):
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(Ablox.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Ablox.Palette.inkFaint)
            AbloxTextField(L("Search sounds: coin, jump, dog, door…"), text: $search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Ablox.Palette.inkFaint)
                }
                .accessibilityLabel(L("Clear"))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Ablox.Metrics.controlRadius, style: .continuous))
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                chip(L("All"), selected: category == nil) { category = nil }
                ForEach(store.library?.categories ?? []) { entry in
                    chip(entry.title, selected: category == entry.id) {
                        category = category == entry.id ? nil : entry.id
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .background(Capsule().fill(selected ? Ablox.Palette.accent.opacity(0.25) : Ablox.Palette.wash))
                .overlay(Capsule().strokeBorder(selected ? Ablox.Palette.accent : Ablox.Palette.line, lineWidth: 1))
                .foregroundStyle(selected ? Ablox.Palette.accent : Ablox.Palette.ink)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var settingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $recordedCues) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Recorded sounds")).font(.subheadline.weight(.medium)).foregroundStyle(Ablox.Palette.ink)
                        Text(L("The 30 built-in sounds (coin, jump, door…) play recordings. Off: the beeps they had before."))
                            .font(.caption).foregroundStyle(Ablox.Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Ablox.Palette.accent)
                if !store.installed.isEmpty {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label(L("Delete downloaded sounds ({})", Megabytes.text(store.installedBytes)), systemImage: "trash")
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                }
            }
        }
    }

    /// Studio's pick, then the sheet closes.
    private var pickAndClose: ((String) -> Void)? {
        guard let onPick else { return nil }
        let close = dismiss
        return { id in
            onPick(id)
            close()
        }
    }

    private func toggle(_ id: String) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }

    private func copy(_ id: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = id
        #endif
        copied = id
    }
}

/// "Download every sound" (or every sound in one category), with the
/// megabytes so far.
struct SoundDownloadAllCard: View {
    @ObservedObject var store: SoundLibraryStore
    let category: String?

    private var pool: [SoundLibrary.Sound] {
        guard let library = store.library else { return [] }
        return (category.map { library.families(in: $0) } ?? library.families).flatMap(\.sounds)
    }

    var body: some View {
        let pool = self.pool
        let missing = pool.filter { !store.isInstalled($0.id) }
        let have = pool.count - missing.count
        let haveBytes = pool.reduce(0) { store.isInstalled($1.id) ? $0 + $1.bytes : $0 }
        let missingBytes = missing.reduce(0) { $0 + $1.bytes }
        let name = category.flatMap { store.library?.category($0)?.title }
        return VStack(alignment: .leading, spacing: 9) {
            if let bulk = store.bulk {
                if bulk.finished { finished(bulk) } else { running(bulk) }
            } else if store.library != nil {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(missing.isEmpty ? Ablox.Palette.success : Ablox.Palette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(missing.isEmpty ? (name.map { L("Every “{}” sound is on this iPad", $0) } ?? L("Every sound is on this iPad"))
                                             : (name.map { L("Download every “{}” sound", $0) } ?? L("Download every sound")))
                            .font(.headline)
                            .foregroundStyle(Ablox.Palette.ink)
                        Text(L("{} of {} sounds on this iPad · {}", have, pool.count, Megabytes.text(haveBytes)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Ablox.Palette.inkMuted)
                        if !missing.isEmpty {
                            Text(L("{} to go · {}", missing.count, Megabytes.text(missingBytes)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Ablox.Palette.inkFaint)
                        }
                    }
                    Spacer(minLength: 8)
                    if !missing.isEmpty {
                        Button {
                            store.downloadAll(category: category)
                        } label: {
                            Label(L("Download all"), systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(NeonButtonStyle(.primary))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Ablox.Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Ablox.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Ablox.Palette.line, lineWidth: 1)
        )
    }

    private func sizeText(_ bulk: BulkDownload) -> String {
        bulk.expectedBytes.map { bulk.bytes <= $0 ? Megabytes.text(bulk.bytes, of: $0) : Megabytes.text(bulk.bytes) } ?? Megabytes.text(bulk.bytes)
    }

    private func running(_ bulk: BulkDownload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(bulk.cancelled ? L("Stopping…") : L("Downloading sounds…"), systemImage: "arrow.down.circle")
                    .font(.headline)
                    .foregroundStyle(Ablox.Palette.ink)
                Spacer()
                if !bulk.cancelled {
                    Button(role: .cancel) {
                        store.cancelAll()
                    } label: {
                        Label(L("Stop"), systemImage: "stop.fill")
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                }
            }
            ProgressView(value: bulk.fraction)
                .tint(Ablox.Palette.accent)
            Text(L("{} / {} sounds · {}", bulk.done, bulk.total, sizeText(bulk)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Ablox.Palette.ink)
            if let current = bulk.current {
                Text(L("Now: {}", current))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .lineLimit(1)
            }
        }
    }

    private func finished(_ bulk: BulkDownload) -> some View {
        HStack(spacing: 12) {
            Image(systemName: bulk.failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(bulk.failed > 0 ? Ablox.Palette.warning : Ablox.Palette.success)
            VStack(alignment: .leading, spacing: 3) {
                Text(bulk.cancelled ? L("Stopped. {} sounds downloaded · {}", bulk.done - bulk.failed, Megabytes.text(bulk.bytes))
                                    : L("Done! {} sounds downloaded · {}", bulk.done - bulk.failed, Megabytes.text(bulk.bytes)))
                    .font(.headline)
                    .foregroundStyle(Ablox.Palette.ink)
                if bulk.failed > 0 {
                    Text(L("{} sounds could not be downloaded. Try again later.", bulk.failed))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.warning)
                }
                Text(L("{} on this iPad", Megabytes.text(store.installedBytes)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Ablox.Palette.inkMuted)
            }
            Spacer()
            Button(L("OK")) { store.dismissBulk() }
                .buttonStyle(NeonButtonStyle(.secondary))
        }
    }
}

/// One kind of sound, and its takes when opened.
struct SoundFamilyRow: View {
    let family: SoundLibrary.Family
    @ObservedObject var store: SoundLibraryStore
    let isOpen: Bool
    let copied: String?
    let onPick: ((String) -> Void)?
    let toggle: () -> Void
    let copy: (String) -> Void

    var body: some View {
        let have = family.sounds.filter { store.isInstalled($0.id) }.count
        return VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(for: family.category))
                        .font(.title3)
                        .foregroundStyle(Ablox.Palette.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(family.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ablox.Palette.ink)
                            .multilineTextAlignment(.leading)
                        Text(subtitle(have: have))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Ablox.Palette.inkMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Ablox.Palette.inkFaint)
                }
                .frame(minHeight: Ablox.Metrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(family.sounds) { sound in
                        SoundTakeButton(sound: sound, store: store, copied: copied == sound.id, onPick: onPick, copy: copy)
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Ablox.Metrics.controlRadius, style: .continuous))
    }

    private func subtitle(have: Int) -> String {
        let english = Localization.language == .japanese && !family.japanese.isEmpty ? family.english + " · " : ""
        let downloaded = have > 0 ? " · " + L("{} downloaded", have) : ""
        return english + L("{} takes · {}", family.sounds.count, Megabytes.text(family.bytes)) + downloaded
    }

    static func symbol(for category: String) -> String {
        switch category {
        case "ui": return "hand.tap.fill"
        case "retro-game": return "gamecontroller.fill"
        case "transition": return "wind"
        case "impact": return "burst.fill"
        case "ambience": return "leaf.fill"
        case "water": return "drop.fill"
        case "fire-electric": return "flame.fill"
        case "footsteps": return "figure.walk"
        case "door": return "door.left.hand.open"
        case "mechanical": return "gearshape.2.fill"
        case "paper-fabric": return "doc.fill"
        case "glass": return "wineglass.fill"
        case "animal": return "pawprint.fill"
        case "crowd": return "person.3.fill"
        case "cartoon": return "face.smiling.fill"
        case "magic-scifi": return "wand.and.stars"
        case "horror": return "moon.fill"
        case "feedback": return "checkmark.seal.fill"
        case "instrument": return "music.note"
        case "office": return "printer.fill"
        case "human": return "person.wave.2.fill"
        case "vehicle": return "car.fill"
        case "household": return "house.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// One take: tap to listen; copy its name, or use it in Studio.
struct SoundTakeButton: View {
    let sound: SoundLibrary.Sound
    @ObservedObject var store: SoundLibraryStore
    let copied: Bool
    let onPick: ((String) -> Void)?
    let copy: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                Task { await store.preview(sound) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(store.isInstalled(sound.id) ? Ablox.Palette.success : Ablox.Palette.accent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(sound.shortName + " · " + sound.lengthText)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Ablox.Palette.ink)
                        if !sound.title.isEmpty {
                            Text(sound.title)
                                .font(.caption2)
                                .foregroundStyle(Ablox.Palette.inkFaint)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .frame(minWidth: 60, minHeight: Ablox.Metrics.minimumTapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Listen to {}", sound.id))
            Spacer(minLength: 0)
            Button {
                if let onPick { onPick(sound.id) } else { copy(sound.id) }
            } label: {
                Image(systemName: onPick != nil ? "plus.circle.fill" : (copied ? "checkmark" : "doc.on.doc"))
                    .foregroundStyle(copied ? Ablox.Palette.success : Ablox.Palette.inkMuted)
                    .frame(width: 36, height: Ablox.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(onPick != nil ? L("Use {}", sound.id) : L("Copy the name {}", sound.id))
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ablox.Palette.wash))
        .contextMenu {
            Button { copy(sound.id) } label: { Label(L("Copy the name"), systemImage: "doc.on.doc") }
            Text(sound.id)
        }
    }

    private var icon: String {
        if store.downloading.contains(sound.id) { return "arrow.down.circle" }
        return store.isInstalled(sound.id) ? "play.circle.fill" : "play.circle"
    }
}
