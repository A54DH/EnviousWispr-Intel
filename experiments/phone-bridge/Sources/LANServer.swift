#if os(macOS)
import Foundation
import Network
import Darwin

// Only active physical/bridge interfaces with RFC1918 IPv4 addresses are offered.
// No cloud service, DNS dependency, UPnP port forwarding, or wildcard/public binding.
func localAddresses() -> [(name: String, address: String)] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0 else { return [] }
    defer { freeifaddrs(pointer) }
    var result: [(String, String)] = []
    var cursor = pointer
    while let item = cursor {
        defer { cursor = item.pointee.ifa_next }
        let entry = item.pointee
        let name = String(cString: entry.ifa_name)
        guard name.hasPrefix("en") || name.hasPrefix("bridge"),
              (entry.ifa_flags & UInt32(IFF_UP)) != 0,
              let addr = entry.ifa_addr, Int(addr.pointee.sa_family) == AF_INET else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer,
                       socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: buffer)
            if AccessPolicy.isPrivateIPv4(ip) { result.append((name, ip)) }
        }
    }
    return result.sorted { $0.0 < $1.0 }
}

final class LANServer {
    private var listener: NWListener?
    private var connections: [UUID: ClientConnection] = [:]
    let handler: (HTTPRequest) -> HTTPResponse
    init(handler: @escaping (HTTPRequest) -> HTTPResponse) { self.handler = handler }

    func start(address: String, ready: @escaping (String) -> Void, failed: @escaping () -> Void) throws {
        stop()
        guard AccessPolicy.isPrivateIPv4(address) else { throw BridgeError(400, "Choose a private LAN address.") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self = self, let listener = listener, self.listener === listener else { return }
            switch state {
            case .ready:
                if let port = listener.port { ready("\(address):\(port.rawValue)") }
            case .failed: self.stop(); failed()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.connections.count < 8,
                  case .hostPort(let host, _) = connection.endpoint,
                  case .ipv4(let ip) = host, AccessPolicy.isPrivateIPv4(ip.debugDescription)
            else { connection.cancel(); return }
            let id = UUID()
            let client = ClientConnection(connection, handler: self.handler) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            self.connections[id] = client
            client.start()
        }
        listener.start(queue: .main)
    }
    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let active = Array(connections.values)
        connections.removeAll()
        active.forEach { $0.close() }
    }
}

private final class ClientConnection {
    let connection: NWConnection
    let handler: (HTTPRequest) -> HTTPResponse
    let done: () -> Void
    var buffer = Data()
    var deadline: DispatchWorkItem?
    var closed = false
    init(_ connection: NWConnection, handler: @escaping (HTTPRequest) -> HTTPResponse,
         done: @escaping () -> Void) { self.connection = connection; self.handler = handler; self.done = done }
    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.start(queue: .main)
        receive()
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, ended, error in
            guard let self = self, !self.closed else { return }
            if let data = data { self.buffer.append(data) }
            do {
                if let request = try HTTPRequest.parse(self.buffer) { self.reply(self.handler(request)); return }
                if ended || error != nil { self.close() } else { self.receive() }
            } catch let error as BridgeError { self.reply(.error(error)) }
            catch { self.reply(.error(BridgeError(400, "Invalid request."))) }
        }
    }
    func reply(_ response: HTTPResponse) {
        connection.send(content: response.encoded, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
    func close() {
        guard !closed else { return }
        closed = true; deadline?.cancel(); connection.cancel(); buffer.removeAll(); done()
    }
}
#endif
