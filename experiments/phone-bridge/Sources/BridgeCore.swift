import Foundation

// Platform-independent protocol code. The Mac server and the local tests use this file.
struct BridgeError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    // One request per connection. No chunking, pipelining, duplicate headers or unbounded reads.
    static func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 73728 else { throw BridgeError(413, "Request too large.") }
        guard let delimiter = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 8192 { throw BridgeError(431, "Headers too large.") }
            return nil
        }
        guard delimiter.lowerBound <= 8192,
              let header = String(data: data[..<delimiter.lowerBound], encoding: .utf8),
              header.utf8.allSatisfy({ $0 == 13 || $0 == 10 || $0 == 9 || (32...126).contains($0) })
        else { throw BridgeError(400, "Invalid headers.") }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(String(first[0])),
              first[1].hasPrefix("/"), !first[1].hasPrefix("//")
        else { throw BridgeError(400, "Unsupported request.") }
        var headers: [String: String] = [:]
        let allowedName = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw BridgeError(400, "Invalid header.") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowedName.contains($0) }),
                  headers[name] == nil else { throw BridgeError(400, "Invalid or duplicated header.") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { throw BridgeError(400, "Invalid header.") }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil,
              headers["host"] != nil else { throw BridgeError(400, "Unsupported HTTP framing.") }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthText), length <= 65536 else { throw BridgeError(413, "Invalid body length.") }
        guard first[0] != "GET" || length == 0 else { throw BridgeError(400, "GET body not supported.") }
        let expected = delimiter.upperBound + length
        if data.count < expected { return nil }
        guard data.count == expected else { throw BridgeError(400, "Pipelining is not supported.") }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                           body: Data(data[delimiter.upperBound..<expected]))
    }
}

struct HTTPResponse {
    var status: Int
    var type: String
    var body: Data
    static func json(_ status: Int = 200, _ value: [String: Any]) -> HTTPResponse {
        let bytes = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            ?? Data("{\"error\":\"Response encoding failed.\"}".utf8)
        return HTTPResponse(status: status, type: "application/json; charset=utf-8", body: bytes)
    }
    static func error(_ error: BridgeError) -> HTTPResponse { .json(error.status, ["error": error.message]) }
    var encoded: Data {
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Response")\r\n"
            + "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n"
            + "Permissions-Policy: camera=(), microphone=(), geolocation=()\r\n\r\n"
        return Data(header.utf8) + body
    }
}

enum AccessPolicy {
    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let n = Int(part), (0...255).contains(n), String(n) == part else { return nil }
            return n
        }
        guard numbers.count == 4 else { return false }
        return numbers[0] == 10 || (numbers[0] == 192 && numbers[1] == 168)
            || (numbers[0] == 172 && (16...31).contains(numbers[1]))
    }
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in lhs.indices { difference |= lhs[i] ^ rhs[i] }
        return difference == 0
    }
    static func validID(_ id: String) -> Bool {
        id.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func authorize(_ request: HTTPRequest, host: String, secret: String) throws -> String {
        guard request.headers["host"] == host else { throw BridgeError(403, "Wrong receiver address.") }
        guard constantTimeEqual(request.headers["authorization"] ?? "", "Bearer " + secret),
              let client = request.headers["x-client-id"], validID(client)
        else { throw BridgeError(401, "Scan the current QR code on your Mac again.") }
        if request.method == "POST" {
            guard request.headers["origin"] == "http://" + host,
                  request.headers["content-type"]?.lowercased() == "application/json"
            else { throw BridgeError(403, "Only the paired local webpage may send requests.") }
        }
        return client
    }
    static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 12000, text.utf8.count <= 48000 else {
            throw BridgeError(400, "Use between 1 and 12,000 characters per send.")
        }
        guard text.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) || [9, 10, 13].contains(Int($0.value))
        }) else { throw BridgeError(400, "Control characters are not accepted.") }
    }
}

// Do not evict IDs during a session: an old retry must never become a new paste.
// Store a digest, not a transcript. Resetting the receiver also rotates the session secret.
struct DeliveryLedger {
    struct Receipt { let fingerprint: String; let response: HTTPResponse }
    private var receipts: [String: Receipt] = [:]
    let limit: Int
    init(limit: Int = 256) { self.limit = limit }
    func lookup(_ id: String, fingerprint: String) throws -> HTTPResponse? {
        guard AccessPolicy.validID(id) else { throw BridgeError(400, "Invalid send ID.") }
        if let receipt = receipts[id] {
            guard receipt.fingerprint == fingerprint else { throw BridgeError(409, "A retry must contain the same text and target.") }
            return receipt.response
        }
        guard receipts.count < limit else { throw BridgeError(429, "Session limit reached. Stop and restart the Mac receiver.") }
        return nil
    }
    mutating func record(_ id: String, fingerprint: String, response: HTTPResponse) {
        receipts[id] = Receipt(fingerprint: fingerprint, response: response)
    }
}
