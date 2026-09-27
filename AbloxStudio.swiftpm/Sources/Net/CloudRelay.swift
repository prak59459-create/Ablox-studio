import Foundation
import Network

// Internet rooms: the iPads' own connection, passed through the database.
//
// Nothing about a game changes for the internet. The host listens as it
// always does; a guest's `AbloxClient` connects as it always does — only to
// a door on its own iPad (127.0.0.1), which hands everything it is sent to
// the database in numbered pieces, and the host's side hands them on to its
// listener. The bytes are the TLS stream keyed by the room code, so the
// database carries only what it cannot read.
//
//   guest app ⇄ CloudRelayGuest ⇄ relay/<room>/up|down/<link> ⇄ CloudRelayHost ⇄ host listener
//
// One "link" per connection; a reconnect is simply a new link.

/// One connection's two directions through the database.
private final class RelayPipe: @unchecked Sendable {
    let connection: NWConnection
    let database: CloudDatabase
    /// Where this end writes, and where it deletes what it has read.
    let outPath: String
    let inPath: String
    var outbox = RelayOutbox()
    var inbox = RelayInbox()
    var sending = false
    var closed = false
    let queue: DispatchQueue
    var onClose: (() -> Void)?

    init(connection: NWConnection, database: CloudDatabase, outPath: String, inPath: String, queue: DispatchQueue) {
        self.connection = connection
        self.database = database
        self.outPath = outPath
        self.inPath = inPath
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    /// From the local connection, to the database.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.outbox.append(data)
                self.flush()
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    /// One piece at a time, so they arrive in order and each write is small.
    private func flush() {
        guard !sending, !closed, let piece = outbox.take() else { return }
        sending = true
        let path = outPath + "/" + piece.key
        let database = self.database
        Task {
            var tries = 0
            while true {
                do {
                    try await database.put(path, .string(piece.base64))
                    break
                } catch {
                    tries += 1
                    if tries >= 5 { self.queue.async { self.close() }; return }
                    try? await Task.sleep(nanoseconds: UInt64(tries) * 400_000_000)
                }
            }
            self.queue.async {
                self.sending = false
                self.flush()
            }
        }
    }

    /// From the database (everything waiting under this link), to the
    /// local connection; then the pieces read are deleted.
    func deliver(_ pieces: [String: JSONValue]) {
        guard !closed else { return }
        let ready = inbox.receive(pieces)
        if !ready.isEmpty {
            connection.send(content: ready, completion: .contentProcessed { _ in })
        }
        let consumed = inbox.takeConsumed()
        guard !consumed.isEmpty else { return }
        var removals: [String: JSONValue] = [:]
        for key in consumed { removals[key] = .null }
        let database = self.database
        let path = inPath
        Task { try? await database.update(path, removals) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }
}

// MARK: - The host's side

/// Lets internet guests reach this iPad's listener through the database.
public final class CloudRelayHost: @unchecked Sendable {
    private let database: CloudDatabase
    private let room: String
    private let localPort: UInt16
    private let queue = DispatchQueue(label: "ablox.cloud.relay.host")
    private var pipes: [String: RelayPipe] = [:]
    /// Links that have ended, never reopened by a late piece.
    private var finished: Set<String> = []
    private var watcher: Task<Void, Never>?
    private var linkWatcher: Task<Void, Never>?

    public init(database: CloudDatabase, room: String, localPort: UInt16) {
        self.database = database
        self.room = room
        self.localPort = localPort
    }

    public func start() {
        let stream = database.stream(CloudPath.up(room))
        watcher = Task { [weak self] in
            var mirror = CloudMirror()
            for await event in stream {
                mirror.apply(event)
                let links = mirror.value.object ?? [:]
                guard let relay = self else { return }
                relay.queue.async { relay.update(links) }
            }
        }
        // A guest who leaves removes their link: their connection here goes too.
        let links = database.stream(CloudPath.relay(room) + "/links")
        linkWatcher = Task { [weak self] in
            var mirror = CloudMirror()
            for await event in links {
                mirror.apply(event)
                let open = Set((mirror.value.object ?? [:]).keys)
                guard let relay = self else { return }
                relay.queue.async { relay.closeLinks(notIn: open) }
            }
        }
    }

    /// Links the list has shown: only one that was listed and is gone has
    /// ended (the two streams are not in step, so an old list can arrive
    /// after a new guest's first piece).
    private var listed: Set<String> = []

    private func closeLinks(notIn open: Set<String>) {
        for (link, pipe) in pipes where listed.contains(link) && !open.contains(link) {
            pipe.close()
        }
        listed = listed.intersection(Set(pipes.keys)).union(open)
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        linkWatcher?.cancel()
        linkWatcher = nil
        queue.async {
            for pipe in self.pipes.values { pipe.close() }
            self.pipes.removeAll()
        }
        let database = self.database
        let room = self.room
        Task { try? await database.delete(CloudPath.relay(room)) }
    }

    private func update(_ links: [String: JSONValue]) {
        for (link, pieces) in links {
            guard CloudPath.isSafeKey(link), !finished.contains(link) else { continue }
            let pipe = pipes[link] ?? open(link)
            pipe?.deliver(pieces.object ?? [:])
        }
    }

    private func open(_ link: String) -> RelayPipe? {
        guard pipes.count < 64, let port = NWEndpoint.Port(rawValue: localPort) else { return nil }
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        let pipe = RelayPipe(connection: connection, database: database, outPath: CloudPath.down(room, link),
                             inPath: CloudPath.up(room, link), queue: queue)
        pipe.onClose = { [weak self] in
            guard let self else { return }
            self.pipes[link] = nil
            self.finished.insert(link)
            let database = self.database
            let room = self.room
            Task {
                try? await database.delete(CloudPath.down(room, link))
                try? await database.delete(CloudPath.up(room, link))
                try? await database.delete(CloudPath.link(room, link))
            }
        }
        pipes[link] = pipe
        pipe.start()
        return pipe
    }
}

// MARK: - A guest's side

/// A door on this iPad that leads to an internet room: connect to
/// 127.0.0.1 on `port`, and the connection comes out at the room's host.
public final class CloudRelayGuest: @unchecked Sendable {
    private let database: CloudDatabase
    private let room: String
    private let queue = DispatchQueue(label: "ablox.cloud.relay.guest")
    private var listener: NWListener?
    private var pipes: [String: RelayPipe] = [:]
    private var watchers: [String: Task<Void, Never>] = [:]

    public init(database: CloudDatabase, room: String) {
        self.database = database
        self.room = room
    }

    /// Opens the door and says which port it is on.
    public func start() async throws -> UInt16 {
        let uid = try await database.auth.signIn()
        let parameters = NWParameters.tcp
        // Only this iPad can use the door.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, uid: uid)
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
        queue.async {
            for task in self.watchers.values { task.cancel() }
            self.watchers.removeAll()
            for pipe in self.pipes.values { pipe.close() }
            self.pipes.removeAll()
        }
    }

    private func accept(_ connection: NWConnection, uid: String) {
        // One app, one connection at a time; a reconnect replaces the last.
        for pipe in pipes.values { pipe.close() }
        let link = CloudIDs.newLinkID()
        let database = self.database
        let room = self.room
        let pipe = RelayPipe(connection: connection, database: database, outPath: CloudPath.up(room, link),
                             inPath: CloudPath.down(room, link), queue: queue)
        pipe.onClose = { [weak self] in
            guard let self else { return }
            self.pipes[link] = nil
            self.watchers.removeValue(forKey: link)?.cancel()
            Task {
                try? await database.delete(CloudPath.up(room, link))
                try? await database.delete(CloudPath.down(room, link))
                try? await database.delete(CloudPath.link(room, link))
            }
        }
        pipes[link] = pipe

        // The link is claimed first — the rules let only its guest write it —
        // and only then does the connection start sending.
        Task {
            do {
                try await database.put(CloudPath.link(room, link), .object(["guest": .string(uid), "at": .serverTime]))
            } catch {
                self.queue.async { pipe.close() }
                return
            }
            let stream = database.stream(CloudPath.down(room, link))
            let claim = database.stream(CloudPath.link(room, link))
            let watcher = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        var mirror = CloudMirror()
                        for await event in stream {
                            mirror.apply(event)
                            let pieces = mirror.value.object ?? [:]
                            self.queue.async { pipe.deliver(pieces) }
                        }
                    }
                    group.addTask {
                        // The host ended the connection: the link is gone.
                        var mirror = CloudMirror()
                        var seen = false
                        for await event in claim {
                            mirror.apply(event)
                            if mirror.value != .null { seen = true }
                            if event.kind == .cancel || (seen && mirror.value == .null) {
                                self.queue.async { pipe.close() }
                                return
                            }
                        }
                    }
                }
            }
            self.queue.async {
                self.watchers[link] = watcher
                pipe.start()
            }
        }
    }
}
