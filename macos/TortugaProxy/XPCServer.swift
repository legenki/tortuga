import Foundation
import TortugaProxyKit

/// The extension's Mach service: only the Tortuga app of this team may connect.
final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let requirement: String

    init?(bundle: Bundle) {
        guard let extensionInfo = bundle.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let service = extensionInfo["NEMachServiceName"] as? String,
              let team = bundle.object(forInfoDictionaryKey: "TortugaTeamID") as? String else { return nil }
        listener = NSXPCListener(machServiceName: service)
        requirement = #"anchor apple generic and identifier "org.tortuga.app" and certificate leaf[subject.OU] = "\#(team)""#
        super.init()
    }

    func start() {
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ProxyXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: AppXPC.self)
        let session = Session(connection: connection)
        connection.exportedObject = session
        connection.invalidationHandler = { session.end() }
        connection.resume()
        return true
    }
}

/// One app connection: commands in, states out.
private final class Session: NSObject, ProxyXPC, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private var pusher: Task<Void, Never>?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func perform(_ command: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let decoded = Wire.decode(ExtensionCommand.self, command) else {
            reply(Wire.encode(ExtensionReply.failure("The extension can't read that command")))
            return
        }
        Task { reply(Wire.encode(await Shared.handle(decoded))) }
    }

    func subscribe() {
        guard let app = connection?.remoteObjectProxy as? AppXPC else { return }
        let boxed = Unchecked(value: app)
        pusher?.cancel()
        pusher = Task {
            for await state in await Shared.core.states() {
                boxed.value.stateChanged(Wire.encode(state))
            }
        }
    }

    func end() {
        pusher?.cancel()
    }
}
