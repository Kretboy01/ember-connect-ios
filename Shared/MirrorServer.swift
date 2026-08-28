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
    /// Set once the listener has been rebuilt without its Bonjour service —
    /// see `start(advertise:)`. Bounds the retry to a single attempt.
    private var advertisementDisabled = false

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
        start(advertise: true)
    }

    /// - Parameter advertise: publish `_ember-mirror._tcp` so a desktop on the
    ///   same network can find the phone without being told its address.
    ///
    ///   Advertising is *not* free: since iOS 14 registering a Bonjour service
    ///   requires local-network permission, and a broadcast extension has no
    ///   way to present the prompt that grants it. If the user has not already
    ///   allowed the containing app, `NWListener` fails outright — taking the
    ///   plain TCP listener down with it and killing mirroring over USB, which
    ///   never needed the network in the first place. So a failure while
    ///   advertising retries once without it: discovery is a convenience,
    ///   the socket is the product.
    private func start(advertise: Bool) {
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

        if advertise && !advertisementDisabled {
            created.service = NWListener.Service(name: MirrorProtocol.bonjourName,
                                                 type: MirrorProtocol.bonjourType)
        }

        created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // `self` is captured weakly, not strongly: the listener holds this
        // closure for its lifetime, so a strong capture would keep the server
        // alive after the broadcast ends.
        let boundPort = port
        let advertising = created.service != nil
        created.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                NSLog("[Mirror] listening on \(boundPort)\(advertising ? " (advertised)" : "")")
            case .failed(let error):
                NSLog("[Mirror] listener failed: \(error)")
                guard let self else { return }
                if advertising {
                    // Almost certainly local-network permission. Drop the
                    // advertisement and come back up as a plain socket.
                    NSLog("[Mirror] retrying without Bonjour advertisement")
                    self.advertisementDisabled = true
                    self.stop()
                    self.start(advertise: false)
                }
            default:
                break
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
              width: Int = 0,
              height: Int = 0,
              flags: UInt8 = 0,
              timestampMicros: UInt64 = 0) {
        let header = MirrorProtocol.Header(
            type: type,
            flags: flags,
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
