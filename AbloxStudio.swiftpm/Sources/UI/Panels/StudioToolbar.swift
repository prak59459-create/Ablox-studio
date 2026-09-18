import SwiftUI
import AbloxCore
import EditorCore

/// The top bar: tools, snapping, undo, sharing, and the Play switch.
struct StudioToolbar: View {
    @ObservedObject var session: StudioSession
    var onFrameSelection: () -> Void
    var onExit: () -> Void

    @State private var showShareSheet = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onExit) {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ablox.Palette.ink)
            .accessibilityLabel("Back to projects")

            worldTitle

            Divider().frame(height: 26).background(Color.white.opacity(0.1))

            toolPicker

            Divider().frame(height: 26).background(Color.white.opacity(0.1))

            snapControls

            Divider().frame(height: 26).background(Color.white.opacity(0.1))

            historyControls

            Spacer(minLength: 8)

            if let status = session.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.accent)
                    .transition(.opacity)
            }

            collaboratorBadge
            shareButton
            playButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .animation(.easeInOut(duration: 0.2), value: session.statusMessage)
        .sheet(isPresented: $showShareSheet) { shareSheet }
    }

    // MARK: Pieces

    private var worldTitle: some View {
        HStack(spacing: 6) {
            Text(session.document.world.name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Ablox.Palette.ink)
                .lineLimit(1)
            if session.document.hasUnsavedChanges {
                Circle()
                    .fill(Ablox.Palette.warning)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unsaved changes")
            }
        }
        .frame(minWidth: 90, alignment: .leading)
    }

    private var toolPicker: some View {
        HStack(spacing: 3) {
            ForEach(EditorDocument.Tool.allCases) { tool in
                let isActive = session.document.tool == tool
                Button {
                    session.setTool(tool)
                } label: {
                    Image(systemName: tool.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isActive ? Ablox.Palette.accent.opacity(0.3) : .clear)
                        )
                        .foregroundStyle(isActive ? Ablox.Palette.accent : Ablox.Palette.inkMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.displayName)
                .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .disabled(session.mode == .play)
        .opacity(session.mode == .play ? 0.4 : 1)
    }

    private var snapControls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Grid", selection: Binding(
                    get: { session.gridSize },
                    set: { session.gridSize = $0 }
                )) {
                    Text("Off").tag(Float(0))
                    Text("0.25 m").tag(Float(0.25))
                    Text("0.5 m").tag(Float(0.5))
                    Text("1 m").tag(Float(1))
                    Text("2 m").tag(Float(2))
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: session.gridSize > 0 ? "grid" : "grid.circle")
                        .font(.caption)
                    Text(session.gridSize > 0 ? formatted(session.gridSize) : "Off")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(session.gridSize > 0 ? Ablox.Palette.accent : Ablox.Palette.inkMuted)
            }
            .accessibilityLabel("Grid snapping")

            Menu {
                Picker("Angle", selection: Binding(
                    get: { session.angleSnap },
                    set: { session.angleSnap = $0 }
                )) {
                    Text("Off").tag(Float(0))
                    Text("15°").tag(Float(15))
                    Text("45°").tag(Float(45))
                    Text("90°").tag(Float(90))
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "angle").font(.caption)
                    Text(session.angleSnap > 0 ? "\(Int(session.angleSnap))°" : "Off")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(session.angleSnap > 0 ? Ablox.Palette.accent : Ablox.Palette.inkMuted)
            }
            .accessibilityLabel("Angle snapping")
        }
        .disabled(session.mode == .play)
        .opacity(session.mode == .play ? 0.4 : 1)
    }

    private func formatted(_ value: Float) -> String {
        value == value.rounded() ? "\(Int(value))m" : String(format: "%.2fm", value)
    }

    private var historyControls: some View {
        HStack(spacing: 3) {
            toolbarButton("arrow.uturn.backward", label: session.document.history.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                session.undo()
            }
            .disabled(!session.document.history.canUndo)

            toolbarButton("arrow.uturn.forward", label: session.document.history.redoLabel.map { "Redo \($0)" } ?? "Redo") {
                session.redo()
            }
            .disabled(!session.document.history.canRedo)

            toolbarButton("scope", label: "Frame selection", action: onFrameSelection)

            toolbarButton("doc.on.doc", label: "Duplicate") {
                session.duplicateSelection()
            }
            .disabled(session.document.selection.isEmpty)
        }
        .disabled(session.mode == .play)
        .opacity(session.mode == .play ? 0.4 : 1)
    }

    private func toolbarButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ablox.Palette.inkMuted)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var collaboratorBadge: some View {
        let others = session.collaborators.count
        if others > 1 {
            Badge("\(others) editing", color: Ablox.Palette.success, systemImage: "person.2.fill")
        }
    }

    private var shareButton: some View {
        Button {
            if session.isHosting {
                showShareSheet = true
            } else {
                session.startHosting()
                showShareSheet = true
            }
        } label: {
            Image(systemName: session.isHosting ? "antenna.radiowaves.left.and.right" : "person.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(session.isHosting ? Ablox.Palette.success : Ablox.Palette.inkMuted)
        .accessibilityLabel(session.isHosting ? "Sharing this project" : "Share this project")
    }

    private var playButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { session.toggleMode() }
        } label: {
            Label(
                session.mode == .edit ? "Play" : "Stop",
                systemImage: session.mode == .edit ? "play.fill" : "stop.fill"
            )
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(session.mode == .edit ? AnyShapeStyle(Ablox.Palette.brand) : AnyShapeStyle(Ablox.Palette.danger))
            .foregroundStyle(session.mode == .edit ? .black : .white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Share sheet

    private var shareSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(Ablox.Palette.accent)
                .padding(.top, 28)

            Text("Build together")
                .font(.title2.weight(.bold))

            Text("Other iPads running Ablox Studio can find this project and edit it with you. Give them the code.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Ablox.Palette.inkMuted)
                .padding(.horizontal, 30)

            if let code = session.roomCode {
                Text(RoomCode.formatted(code))
                    .font(.system(size: 36, weight: .black, design: .monospaced))
                    .kerning(3)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 30)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Ablox.Palette.accent.opacity(0.5), lineWidth: 1.5)
                    )
                    .textSelection(.enabled)
            } else {
                ProgressView().tint(Ablox.Palette.accent).padding(.vertical, 30)
            }

            Label("Encrypted with TLS 1.3", systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(Ablox.Palette.success)

            Spacer(minLength: 0)

            HStack(spacing: 11) {
                Button("Stop sharing") {
                    session.stopSharing()
                    showShareSheet = false
                }
                .buttonStyle(NeonButtonStyle(.secondary, fullWidth: true))

                Button("Done") { showShareSheet = false }
                    .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 26)
        }
        .frame(maxWidth: 460)
        .presentationDetents([.height(460)])
        .presentationBackground(.ultraThinMaterial)
    }
}
