import SwiftUI
import AbloxCore

/// Play: the world full screen as Ablox runs it alone — a character to walk
/// and jump with, the scripts running, and what they put on the screen.
///
/// The game is the same code the player app uses (`SessionCoordinator`,
/// `GameViewport`, and the play screen's stick, buttons and script HUD,
/// mirrored from the client), so what works here works in Ablox.
struct StudioTestPlayView: View {
    @StateObject private var game: SessionCoordinator
    let onExit: () -> Void

    /// The stick, the camera and the buttons, read by the 3D view every
    /// frame; not view state, so a thumb on the stick does not redraw this.
    @State private var controls = PlayControls()
    @State private var isJumping = false
    @State private var isFiring = false

    init(world: WorldDocument, peerID: PeerID, profile: AvatarProfile, onExit: @escaping () -> Void) {
        let tested = TestPlay.world(world)
        // Started here rather than on appear: the 3D view reads the world's
        // sky as it is made.
        _game = StateObject(wrappedValue: {
            let game = SessionCoordinator(localPeerID: peerID, profile: profile)
            game.startSoloSession(world: tested)
            return game
        }())
        self.onExit = onExit
    }

    var body: some View {
        ZStack {
            GameViewport(session: game, controls: controls)
                .ignoresSafeArea()
            if game.scripted.showsControls {
                controlsLayer
            }
            ScriptHUDLayer(session: game)
            PartsHUDLayer(session: game, readAloud: false)
            if !game.scriptLog.isEmpty {
                ScriptLogBanner(session: game)
                    .padding(.leading, 18)
                    .padding(.bottom, 130)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            topBar
            startingNotice
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onChange(of: isJumping) { _, held in controls.isJumping = held }
        .onChange(of: isFiring) { _, held in controls.isFiring = held }
        .onDisappear { game.leave() }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                Button {
                    game.leave()
                    onExit()
                } label: {
                    Label(L("Stop"), systemImage: "stop.fill")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Ablox.Palette.danger, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Text(L("Test play — this is how your game plays in Ablox."))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(Ablox.Palette.inkMuted)
                Spacer()
            }
            .padding(14)
            Spacer()
        }
    }

    /// While the game starts, or why it could not.
    @ViewBuilder private var startingNotice: some View {
        switch game.status {
        case .connecting, .idle, .searching:
            ProgressView(L("Starting the game…"))
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        case let .error(reason):
            VStack(spacing: 10) {
                Text(L("The game could not start."))
                    .font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .active, .reconnecting:
            EmptyView()
        }
    }

    // MARK: Controls

    private var controlsLayer: some View {
        GeometryReader { proxy in
            let half = proxy.size.width / 2
            ZStack {
                // The stick owns the left half, the camera the right.
                HStack(spacing: 0) {
                    VirtualJoystick(value: stickBinding, fixedOnLeft: true) { controls.stickRunning = $0 }
                        .frame(width: half)
                    CameraPad(yaw: yawBinding, pitch: pitchBinding, pitchRange: pitchRange)
                        .frame(width: half)
                }
                VStack(alignment: .trailing, spacing: 14) {
                    Spacer()
                    if game.scripted.weapon != nil {
                        CombatControls(session: game, isFiring: $isFiring)
                    }
                    JumpButton(isPressed: $isJumping)
                }
                .padding(44)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var pitchRange: ClosedRange<Float> {
        game.scripted.camera.mode == .firstPerson ? -80...80 : -75...20
    }

    private var stickBinding: Binding<Vec3> {
        let held = controls
        return Binding(get: { held.stick }, set: { held.stick = $0 })
    }

    private var yawBinding: Binding<Float> {
        let held = controls
        return Binding(get: { held.cameraYaw }, set: { held.cameraYaw = $0 })
    }

    private var pitchBinding: Binding<Float> {
        let held = controls
        return Binding(get: { held.cameraPitch }, set: { held.cameraPitch = $0 })
    }
}
