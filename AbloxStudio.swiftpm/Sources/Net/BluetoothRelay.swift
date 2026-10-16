import Foundation
import CoreBluetooth
import Network
import AbloxCore

// Rooms over Bluetooth: the iPads' own connection, passed through a
// Bluetooth channel (L2CAP), the way an internet room passes it through the
// database (CloudRelay.swift).
//
// Nothing about a game changes. The host listens as it always does; a
// guest's `AbloxClient` connects to a door on its own iPad (127.0.0.1), and
// the bytes — the TLS stream keyed by the room code — go through Bluetooth
// to the host, whose side hands them to its listener. One room takes guests
// on the router, over the internet and over Bluetooth at once, and needs no
// Wi-Fi at all for the ones nearby.
//
//   guest app ⇄ BluetoothRelayGuest ⇄ L2CAP channel ⇄ BluetoothRelayHost ⇄ host listener
//
// A room says what it is in a small description (`BluetoothRoomInfo`), read
// from the room's Bluetooth service before joining.

private let serviceUUID = CBUUID(string: BluetoothRoomInfo.serviceID)
private let infoUUID = CBUUID(string: BluetoothRoomInfo.infoID)

/// One Bluetooth channel joined to one local connection, both ways. Runs on
/// one serial queue: the channel's streams and the connection both call
/// back there.
private final class ChannelBridge: NSObject, StreamDelegate, @unchecked Sendable {
    private let channel: CBL2CAPChannel
    private let connection: NWConnection
    private let queue: DispatchQueue
    /// Waiting to go into the channel.
    private var pending = Data()
    private var closed = false
    var onClose: (() -> Void)?

    init(channel: CBL2CAPChannel, connection: NWConnection, queue: DispatchQueue) {
        self.channel = channel
        self.connection = connection
        self.queue = queue
    }

    func start() {
        guard let input = channel.inputStream, let output = channel.outputStream else {
            close()
            return
        }
        input.delegate = self
        output.delegate = self
        CFReadStreamSetDispatchQueue(input as CFReadStream, queue)
        CFWriteStreamSetDispatchQueue(output as CFWriteStream, queue)
        input.open()
        output.open()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        if connection.state == .setup { connection.start(queue: queue) }
        receive()
    }

    /// From the local connection, into the channel.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.pending.append(data)
                self.write()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func write() {
        guard !closed, let output = channel.outputStream else { return }
        while !pending.isEmpty, output.hasSpaceAvailable {
            let count = min(pending.count, 4096)
            let written = pending.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: count)
            }
            if written < 0 {
                close()
                return
            }
            if written == 0 { return }
            pending.removeFirst(written)
        }
    }

    /// From the channel, into the local connection.
    private func read(_ input: InputStream) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                close()
                return
            }
            if count == 0 { return }
            connection.send(content: Data(buffer[0..<count]), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.queue.async { self?.close() } }
            })
        }
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            if let input = stream as? InputStream { read(input) }
        case .hasSpaceAvailable:
            write()
        case .endEncountered, .errorOccurred:
            close()
        default:
            break
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        for stream in [channel.inputStream as Stream?, channel.outputStream as Stream?] {
            stream?.delegate = nil
            stream?.close()
        }
        connection.cancel()
        let done = onClose
        onClose = nil
        done?()
    }
}

// MARK: - A host's side

/// Puts the room this iPad is hosting in the air: a description to read and
/// a channel to open, each channel handed on to the room's listener.
public final class BluetoothRelayHost: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ablox.bluetooth.relay.host")
    private let localPort: UInt16
    private var room: BluetoothRoomInfo
    private var manager: CBPeripheralManager?
    private var channel: CBL2CAPPSM?
    private var bridges: [ObjectIdentifier: ChannelBridge] = [:]
    private var stopped = false
    /// Something stopped the room going into the air (on the main actor).
    public var onProblem: (@MainActor (String) -> Void)?

    /// `room` is everything but the channel, which Bluetooth picks.
    public init(localPort: UInt16, room: BluetoothRoomInfo) {
        self.localPort = localPort
        self.room = room
    }

    public func start() {
        queue.async {
            guard !self.stopped, self.manager == nil else { return }
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    /// How full the room is now, for the next guest to read.
    public func update(players: Int) {
        queue.async { self.room.players = max(0, min(players, 999)) }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            for bridge in self.bridges.values { bridge.close() }
            self.bridges.removeAll()
            guard let manager = self.manager else { return }
            manager.stopAdvertising()
            manager.removeAllServices()
            if let channel = self.channel { manager.unpublishL2CAPChannel(channel) }
            self.channel = nil
            manager.delegate = nil
            self.manager = nil
        }
    }

    private func problem(_ message: String) {
        guard let report = onProblem else { return }
        Task { @MainActor in report(message) }
    }

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if channel == nil, !stopped { peripheral.publishL2CAPChannel(withEncryption: false) }
        case .poweredOff, .resetting:
            // Bluetooth turned off takes the channel and the service with it:
            // both go up again when it comes back.
            channel = nil
        case .unauthorized:
            problem(L("Bluetooth is turned off for Ablox. Turn it on in the iPad's Settings → Ablox."))
        case .unsupported:
            problem(L("This iPad cannot host over Bluetooth."))
        default:
            break
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard error == nil, !stopped else {
            if let error { problem(error.localizedDescription) }
            return
        }
        channel = PSM
        let info = CBMutableCharacteristic(type: infoUUID, properties: [.read], value: nil, permissions: [.readable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [info]
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil, !stopped else {
            if let error { problem(error.localizedDescription) }
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                     CBAdvertisementDataLocalNameKey: "Ablox"])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == infoUUID, let channel else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        var info = room
        info.channel = channel
        guard let piece = BluetoothRoomInfo.piece(of: info.encoded(), at: request.offset) else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = piece
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil, !stopped, bridges.count < 32,
              let port = NWEndpoint.Port(rawValue: localPort) else { return }
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        let bridge = ChannelBridge(channel: channel, connection: connection, queue: queue)
        let key = ObjectIdentifier(bridge)
        bridges[key] = bridge
        bridge.onClose = { [weak self] in self?.bridges[key] = nil }
        bridge.start()
    }
}

// MARK: - Finding rooms nearby

/// A room nearby over Bluetooth.
public struct BluetoothRoom: Identifiable, Hashable, Sendable {
    /// The host iPad, as Bluetooth knows it on this iPad.
    public let id: UUID
    public var info: BluetoothRoomInfo
    public var seenAt: Date
}

/// Looks for rooms nearby over Bluetooth, reads what each one is, and opens
/// the way into one (`BluetoothRelayGuest`).
public final class BluetoothRoomFinder: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ablox.bluetooth.finder")
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var rooms: [UUID: BluetoothRoom] = [:]
    private var reading: Set<UUID> = []
    private var lastRead: [UUID: Date] = [:]
    /// Value pieces read so far, for a long description.
    private var opening: [UUID: (psm: CBL2CAPPSM, done: (CBL2CAPChannel?) -> Void)] = [:]
    private var scanning = false

    /// The rooms nearby, newest first (on the main actor).
    public var onRooms: (@MainActor ([BluetoothRoom]) -> Void)?
    public var onProblem: (@MainActor (String) -> Void)?

    public func start() {
        queue.async {
            self.scanning = true
            if let central = self.central {
                if central.state == .poweredOn { self.scan() }
            } else {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async {
            self.scanning = false
            self.central?.stopScan()
            for (id, peripheral) in self.peripherals where self.opening[id] == nil {
                self.central?.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func scan() {
        central?.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private var lastPublished = Date.distantPast
    private var lastList: [UUID] = []

    private func publish() {
        // A room not seen for half a minute has gone.
        let now = Date()
        rooms = rooms.filter { now.timeIntervalSince($0.value.seenAt) < 30 }
        let list = rooms.values.sorted { $0.seenAt > $1.seenAt }
        // Every advertisement is heard: tell the screen at most once a second,
        // unless a room came or went.
        let ids = list.map(\.id).sorted { $0.uuidString < $1.uuidString }
        guard ids != lastList || now.timeIntervalSince(lastPublished) > 1 else { return }
        lastList = ids
        lastPublished = now
        guard let report = onRooms else { return }
        Task { @MainActor in report(list) }
    }

    private func problem(_ message: String) {
        guard let report = onProblem else { return }
        Task { @MainActor in report(message) }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanning { scan() }
        case .unauthorized:
            problem(L("Bluetooth is turned off for Ablox. Turn it on in the iPad's Settings → Ablox."))
        case .poweredOff:
            problem(L("Bluetooth is off. Turn it on to find rooms nearby without Wi-Fi."))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        peripherals[id] = peripheral
        if var room = rooms[id] {
            room.seenAt = Date()
            rooms[id] = room
        }
        // Read what the room is now and then (how full it is changes).
        if !reading.contains(id), Date().timeIntervalSince(lastRead[id] ?? .distantPast) > 8 {
            reading.insert(id)
            lastRead[id] = Date()
            central.connect(peripheral)
        }
        publish()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        if let wanted = opening[peripheral.identifier] {
            peripheral.openL2CAPChannel(wanted.psm)
        } else {
            peripheral.discoverServices([serviceUUID])
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        reading.remove(id)
        if let wanted = opening.removeValue(forKey: id) { wanted.done(nil) }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reading.remove(peripheral.identifier)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            finishReading(peripheral)
            return
        }
        peripheral.discoverCharacteristics([infoUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let info = service.characteristics?.first(where: { $0.uuid == infoUUID }) else {
            finishReading(peripheral)
            return
        }
        peripheral.readValue(for: info)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        if error == nil, let value = characteristic.value, let info = BluetoothRoomInfo.decode(value) {
            rooms[id] = BluetoothRoom(id: id, info: info, seenAt: Date())
            lastPublished = .distantPast
            publish()
        }
        finishReading(peripheral)
    }

    private func finishReading(_ peripheral: CBPeripheral) {
        reading.remove(peripheral.identifier)
        if opening[peripheral.identifier] == nil { central?.cancelPeripheralConnection(peripheral) }
    }

    // MARK: Opening a channel

    /// A channel to the room on `roomID`, or nil if it could not be opened.
    fileprivate func openChannel(to roomID: UUID, done: @escaping (CBL2CAPChannel?) -> Void) {
        queue.async {
            guard let peripheral = self.peripherals[roomID], let room = self.rooms[roomID], let central = self.central,
                  central.state == .poweredOn else {
                done(nil)
                return
            }
            self.opening[roomID] = (psm: room.info.channel, done: done)
            if peripheral.state == .connected {
                peripheral.delegate = self
                peripheral.openL2CAPChannel(room.info.channel)
            } else {
                central.connect(peripheral)
            }
            // Bluetooth may never answer: give up after a while.
            self.queue.asyncAfter(deadline: .now() + 15) {
                if let wanted = self.opening.removeValue(forKey: roomID) { wanted.done(nil) }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let wanted = opening.removeValue(forKey: peripheral.identifier) else { return }
        wanted.done(error == nil ? channel : nil)
    }

    /// Lets the guest door call back on the finder's queue.
    fileprivate var workQueue: DispatchQueue { queue }
}

// MARK: - A guest's side

/// A door on this iPad that leads to a room nearby over Bluetooth: connect
/// to 127.0.0.1 on `port`, and the connection comes out at the room's host.
public final class BluetoothRelayGuest: @unchecked Sendable {
    private let finder: BluetoothRoomFinder
    private let roomID: UUID
    private var listener: NWListener?
    private var bridge: ChannelBridge?

    public init(finder: BluetoothRoomFinder, roomID: UUID) {
        self.finder = finder
        self.roomID = roomID
    }

    /// Opens the door and says which port it is on.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Only this iPad can use the door.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = finder.workQueue
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let bridge = self.bridge
        self.bridge = nil
        finder.workQueue.async { bridge?.close() }
    }

    private func accept(_ connection: NWConnection) {
        // One app, one connection at a time; a reconnect replaces the last.
        bridge?.close()
        bridge = nil
        let queue = finder.workQueue
        connection.start(queue: queue)
        finder.openChannel(to: roomID) { [weak self] channel in
            guard let self, let channel else {
                connection.cancel()
                return
            }
            let bridge = ChannelBridge(channel: channel, connection: connection, queue: queue)
            self.bridge = bridge
            bridge.onClose = { [weak self, weak bridge] in
                if let self, self.bridge === bridge { self.bridge = nil }
            }
            bridge.start()
        }
    }
}
