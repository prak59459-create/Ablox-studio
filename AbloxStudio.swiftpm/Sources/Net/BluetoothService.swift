import Foundation
import Combine
import AbloxCore

/// Rooms over Bluetooth, for the app: the room this iPad hosts goes in the
/// air as well as on the router (and the internet), rooms nearby are found
/// and joined, and a room that moves on to another game is followed — all
/// through `BluetoothRelay`, so a game never knows which way someone came
/// in. Off until Settings turns it on (`AppSettings` keeps the choice):
/// Bluetooth asks the iPad's permission the first time it is used.
@MainActor
public final class BluetoothService: ObservableObject {
    /// Rooms nearby, newest first.
    @Published public private(set) var rooms: [BluetoothRoom] = []
    /// Why Bluetooth cannot be used right now, if it cannot.
    @Published public private(set) var problem: String?
    @Published public private(set) var isHosting = false

    private let finder = BluetoothRoomFinder()
    private var host: BluetoothRelayHost?
    private var guest: BluetoothRelayGuest?
    private var hostTask: Task<Void, Never>?
    private var roleWatch: AnyCancellable?
    private var looking = 0

    /// `UserDefaults`: Settings → Rooms over Bluetooth.
    public static let enabledKey = "ablox.bluetoothRooms"
    /// Whether this version may use Bluetooth at all: true once Package.swift
    /// asks the iPad for Bluetooth (without that, iOS stops the app the
    /// moment Bluetooth is touched). Until then the switch is not shown.
    public static let isReady = false
    public static var isTurnedOn: Bool { isReady && UserDefaults.standard.bool(forKey: enabledKey) }

    public init() {
        finder.onRooms = { [weak self] rooms in self?.rooms = rooms }
        finder.onProblem = { [weak self] message in self?.problem = message }
    }

    // MARK: Finding rooms

    /// While a screen shows rooms nearby. Calls nest: the last to stop stops.
    public func startLooking() {
        looking += 1
        if looking == 1 { finder.start() }
    }

    public func stopLooking() {
        looking = max(0, looking - 1)
        if looking == 0 { finder.stop() }
    }

    // MARK: Hosting

    /// Puts the room this iPad is hosting in the air. Waits for the room to
    /// be open first; call again after it moves to another game (a party),
    /// whose listener and salt are new.
    public func hostRoom(session: SessionCoordinator) {
        stopHosting()
        isHosting = true
        hostTask = Task { [weak self] in
            var keys = session.roomKeys
            var waited = 0
            while keys == nil, waited < 120, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 1
                keys = session.roomKeys
            }
            guard let self, let keys, !Task.isCancelled else { return }
            let info = BluetoothRoomInfo(channel: 0, world: session.world.name,
                                         hostName: session.profile.sanitizedForNetwork().displayName,
                                         hostShortID: RoomTag.short(session.localPeerID),
                                         players: max(1, session.people.count), capacity: keys.capacity,
                                         publicCode: session.isRoomPublic ? keys.code : nil, salt: keys.salt,
                                         needsApproval: session.roomState.needsApproval)
            let relay = BluetoothRelayHost(localPort: keys.port, room: info)
            relay.onProblem = { [weak self] message in self?.problem = message }
            relay.start()
            self.host = relay
            self.watchRole(session)
            // How full, for the next one to read.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                relay.update(players: max(1, session.people.count))
            }
        }
    }

    public func stopHosting() {
        hostTask?.cancel()
        hostTask = nil
        host?.stop()
        host = nil
        isHosting = false
    }

    // MARK: Joining

    /// Joins a room nearby, through a door on this iPad that Bluetooth
    /// carries to the host. `code` is the room's own for a public room.
    public func join(_ room: BluetoothRoom, code: String, session: SessionCoordinator) async {
        leaveRoom()
        let door = BluetoothRelayGuest(finder: finder, roomID: room.id)
        do {
            let port = try await door.start()
            guard let ticket = room.info.ticket(localPort: port, code: code) else {
                door.stop()
                session.noteCloudProblem(L("That code doesn't look right. Check each letter."))
                return
            }
            guest = door
            session.join(ticket: ticket)
            watchRole(session)
            // The host taking everyone on to its next game: the same host,
            // a new room (a new salt) in the air.
            let wanted = room.info.hostShortID
            let oldSalt = room.info.salt
            session.findMovedRoom = { [weak self, weak session] move in
                guard let self, let session, RoomTag.short(move.newHost) == wanted else { return false }
                guard let next = self.rooms.first(where: { $0.info.hostShortID == wanted && $0.info.salt != oldSalt }) else {
                    return false
                }
                await self.join(next, code: move.roomCode, session: session)
                return true
            }
            startLooking()
        } catch {
            door.stop()
            session.noteCloudProblem(error.localizedDescription)
        }
    }

    public func leaveRoom() {
        if guest != nil { stopLooking() }
        guest?.stop()
        guest = nil
    }

    /// Stops hosting or leaves the room when the game ends.
    private func watchRole(_ session: SessionCoordinator) {
        roleWatch = session.$role
            .dropFirst()
            .filter { $0 == .offline }
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.stopHosting()
                    self?.leaveRoom()
                    self?.roleWatch = nil
                }
            }
    }
}
