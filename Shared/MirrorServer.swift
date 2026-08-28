import Foundation
import Network

/// TCP server that publishes the encoded stream.
///
/// The phone listens and the desktop dials in — see `MirrorProtocol` for why
/// that direction is forced by usbmux. The same listener serves Wi-Fi clients,
/// so USB and network use one path.
final class MirrorServer {
    /// Raised when a client attaches, so the encoder can emit an immediate
    /// IDR instead of making it wait for the periodic one.
    var onClientConnected: (() -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Client] = [:]
    private let lock = NSLock()
    private let port: UInt16

    /// A connected desktop, plus the state needed to keep it from becoming a
    /// memory leak when it cannot keep up.
    private final class Client {
        let connection: NWConnection
        /// Bytes handed to the transport but not yet flushed. Used as the
        /// backpressure signal.
        var inFlight = 0
        /// Set once the client has been sent parameter sets; a client that
        /// joins mid-stream must not be fed frames before its SPS.
        var primed = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// Roughly two frames of 4K-ish screen content. Past this the link is the
    /// bottleneck, and buffering only adds latency the user would see as lag,
    /// so frames are dropped instead.
    private let maxInFlightBytes = 4 * 1024 * 1024

    init(port: UInt16 = MirrorProtocol.defaultPort) {
        self.port = port
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        // Screen content is bursty and latency-sensitive: send immediately
        // rather than coalescing small writes.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port),
              let created = try? NWListener(using: parameters, on: endpointPort) else {
            NSLog("[Mirror] could not listen on port \(port)")
            return
        }

        created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // Captures the port by value rather than self — the listener holds
        // this closure for its lifetime, so capturing self would keep the
        // server alive after the broadcast ends.
        let boundPort = port
        created.stateUpdateHandler = { state in
            switch state {
            case .ready: NSLog("[Mirror] listening on \(boundPort)")
            case .failed(let error): NSLog("[Mirror] listener failed: \(error)")
            default: break
            }
        }

        listener = created
        created.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        lock.lock()
        let active = connections.values
        connections.removeAll()
        lock.unlock()

        for client in active {
            client.connection.cancel()
        }
        listener?.cancel()
        listener = nil
    }

    var hasClients: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !connections.isEmpty
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        let key = ObjectIdentifier(connection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                NSLog("[Mirror] client attached")
                self?.onClientConnected?()
            case .failed, .cancelled:
                self?.remove(key)
            default:
                break
            }
        }

        lock.lock()
        connections[key] = client
        lock.unlock()

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func remove(_ key: ObjectIdentifier) {
        lock.lock()
        let client = connections.removeValue(forKey: key)
        lock.unlock()
        client?.connection.cancel()
    }

    // MARK: - Sending

    func send(type: MirrorProtocol.PacketType,
              payload: Data,
              width: Int,
              height: Int,
              timestampMicros: UInt64) {
        let header = MirrorProtocol.Header(
            type: type,
            width: UInt16(clamping: width),
            height: UInt16(clamping: height),
            timestampMicros: timestampMicros,
            length: UInt32(payload.count)
        ).encoded()

        var packet = header
        packet.append(payload)

        // `primed` and `inFlight` are read here and written from send
        // completions on arbitrary queues, so every access stays under the
        // lock. The send itself is issued outside it — NWConnection.send can
        // call back synchronously, which would deadlock a non-recursive lock.
        lock.lock()
        var sendList: [(ObjectIdentifier, Client)] = []
        for (key, client) in connections {
            // Config packets are what prime a client, so they always go out.
            // Frames wait until the client has its parameter sets.
            if type == .config {
                client.primed = true
            } else if !client.primed {
                continue
            }

            // Drop rather than queue when the link is saturated. A keyframe is
            // dropped too if we are this far behind — the next one is at most
            // two seconds out, and admitting it would not help a client that
            // cannot drain what it already has.
            if client.inFlight > maxInFlightBytes {
                continue
            }

            client.inFlight += packet.count
            sendList.append((key, client))
        }
        lock.unlock()

        for (key, client) in sendList {
            client.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.lock()
                client.inFlight -= packet.count
                self.lock.unlock()
                if error != nil {
                    self.remove(key)
                }
            })
        }
    }
}
