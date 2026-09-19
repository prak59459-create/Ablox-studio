import SwiftUI

/// The editor screen: toolbar on top, Explorer left, viewport centre,
/// Inspector right.
struct StudioView: View {
    @ObservedObject var session: StudioSession
    var onExit: () -> Void

    @State private var leftTab: LeftTab = .explorer
    @StateObject private var viewportCommands = ViewportCommands()
    @State private var showPalette = true

    private enum LeftTab: String, CaseIterable, Identifiable {
        case explorer = "Explorer"
        case rules = "Rules"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .explorer: return "list.bullet.indent"
            case .rules: return "bolt.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar(
                session: session,
                onFrameSelection: frameSelection,
                onExit: onExit
            )

            Divider().background(Color.white.opacity(0.08))

            HStack(spacing: 0) {
                if session.mode == .edit {
                    leftPane
                        .frame(width: 270)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider().background(Color.white.opacity(0.08))
                }

                ZStack(alignment: .bottom) {
                    EditorViewport(session: session, commands: viewportCommands)
                        .ignoresSafeArea(edges: .bottom)

                    if session.mode == .edit, showPalette {
                        PartPalette { kind in
                            // Asked for at the moment of the tap, so the part
                            // lands where the camera is looking right now.
                            session.addPart(kind, at: viewportCommands.insertionPoint())
                        }
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if session.mode == .edit {
                        paletteToggle
                    }

                    if session.mode == .play {
                        playModeHint
                    }
                }
                .frame(maxWidth: .infinity)

                if session.mode == .edit {
                    Divider().background(Color.white.opacity(0.08))

                    InspectorPanel(session: session)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Color(red: 0.05, green: 0.06, blue: 0.11))
        .preferredColorScheme(.dark)
        .tint(Ablox.Palette.accent)
        .animation(.easeInOut(duration: 0.22), value: session.mode)
        .statusBarHidden()
    }

    // MARK: Panes

    private var leftPane: some View {
        VStack(spacing: 0) {
            Picker(L("Panel"), selection: $leftTab) {
                ForEach(LeftTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbolName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider().background(Color.white.opacity(0.07))

            switch leftTab {
            case .explorer: ExplorerPanel(session: session)
            case .rules: RulesPanel(session: session)
            }
        }
        .background(.ultraThinMaterial)
    }

    private var paletteToggle: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showPalette.toggle() }
                } label: {
                    Image(systemName: showPalette ? "chevron.down.circle.fill" : "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Ablox.Palette.accent)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(14)
                .accessibilityLabel(showPalette ? "Hide part palette" : "Show part palette")
            }
            Spacer()
        }
    }

    private var playModeHint: some View {
        VStack {
            Spacer()
            Text(L("Testing — tap Stop to keep building"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(Ablox.Palette.inkMuted)
                .padding(.bottom, 22)
        }
    }

    private func frameSelection() {
        // Frames the selection, or the whole world when nothing is selected.
        let bounds = session.document.selectionBounds ?? session.document.world.worldBounds
        viewportCommands.frame(bounds)
    }
}

// MARK: - Part palette

/// The strip of parts you can drop into the world.
struct PartPalette: View {
    var onSelect: (BlockData.PresetKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(BlockData.PresetKind.allCases) { kind in
                    Button {
                        onSelect(kind)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: kind.symbolName)
                                .font(.title3)
                            Text(kind.displayName)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .frame(width: 62, height: 58)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .foregroundStyle(Ablox.Palette.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Add {}", kind.displayName))
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 70)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 22)
    }
}
