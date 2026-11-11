import Foundation
import Network
import NetworkExtension
import TortugaProxyKit

/// One app's TCP flow through the helper's SOCKS port: handshake with the
/// app's ID as username, CONNECT, then bytes both ways until both sides close.
final class TCPRelay: @unchecked Sendable {
    private let flow: NEAppProxyTCPFlow
    private let host: String
    private let port: Int
    private let isolation: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.tortuga.relay")
    private let lock = NSLock()
    private var finished = false
    private var opened = false
    private var closedHalves = 0

    init(flow: NEAppProxyTCPFlow, host: String, port: Int, isolation: String, socksPort: Int) {
        self.flow = flow
        self.host = host
        self.port = port
        self.isolation = isolation
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(socksPort)) ?? 9150, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: handshake()
            case .failed, .cancelled: fail()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func handshake() {
        send(Socks5.greeting) { [self] in
            receive(2) { [self] reply in
                guard (try? Socks5.checkMethod(reply)) != nil else { return fail() }
                send(Socks5.auth(user: isolation, password: "x")) { [self] in
                    receive(2) { [self] reply in
                        guard (try? Socks5.checkAuth(reply)) != nil else { return fail() }
                        send(Socks5.connect(host: host, port: port)) { [self] in
                            receive(5) { [self] head in
                                guard let total = try? Socks5.connectReplyLength(head) else {
                                    proxyLog.notice("relay \(self.isolation, privacy: .public): CONNECT refused, reply \(head, privacy: .public)")
                                    return fail()
                                }
                                receive(total - 5) { [self] _ in openFlow() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func openFlow() {
        flow.open(withLocalFlowEndpoint: nil) { [self] error in
            proxyLog.notice("relay \(self.isolation, privacy: .public): flow opened, error: \(String(describing: error), privacy: .public)")
            guard error == nil else { return fail() }
            lock.withLock { opened = true }
            let app = isolation
            Task { await Shared.core.flowOpened(app: app) }
            flowToSocks()
            socksToFlow()
        }
    }

    private func flowToSocks() {
        flow.readData { [self] data, error in
            proxyLog.debug("relay \(self.isolation, privacy: .public): app sent \(data?.count ?? -1) bytes, error: \(String(describing: error), privacy: .public)")
            guard let data, !data.isEmpty, error == nil else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return halfClosed()
            }
            connection.send(content: data, completion: .contentProcessed { [self] error in
                if error == nil { flowToSocks() } else { fail() }
            })
        }
    }

    private func socksToFlow() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                flow.write(data) { [self] error in
                    if error != nil { return fail() }
                    if isComplete {
                        flow.closeWriteWithError(nil)
                        halfClosed()
                    } else {
                        socksToFlow()
                    }
                }
            } else {
                flow.closeWriteWithError(nil)
                if error != nil { fail() } else { halfClosed() }
            }
        }
    }

    private func send(_ bytes: [UInt8], then next: @escaping @Sendable () -> Void) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [self] error in
            if error == nil { next() } else { fail() }
        })
    }

    private func receive(_ count: Int, then next: @escaping @Sendable ([UInt8]) -> Void) {
        guard count > 0 else { return next([]) }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [self] data, _, _, error in
            guard let data, data.count == count, error == nil else { return fail() }
            next([UInt8](data))
        }
    }

    private func halfClosed() {
        let both = lock.withLock { () -> Bool in
            closedHalves += 1
            return closedHalves >= 2
        }
        if both { finish(error: nil) }
    }

    private func fail() {
        finish(error: NEAppProxyFlowError(.hostUnreachable))
    }

    private func finish(error: (any Error)?) {
        proxyLog.notice("relay \(self.isolation, privacy: .public): finished, error: \(String(describing: error), privacy: .public)")
        let (first, wasOpen) = lock.withLock { () -> (Bool, Bool) in
            defer { finished = true }
            return (!finished, opened)
        }
        guard first else { return }
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        connection.stateUpdateHandler = nil
        connection.cancel()
        if wasOpen {
            let app = isolation
            Task { await Shared.core.flowClosed(app: app) }
        }
    }
}
