import Foundation

var checks = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    guard condition else { fatalError("FAIL: " + name) }
}
func rejects(_ name: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); fatalError("FAIL: expected rejection: " + name) } catch { }
}
func wire(_ extra: String = "", method: String = "GET", body: Data = Data()) -> Data {
    Data("\(method) /api/send HTTP/1.1\r\nHost: 192.168.1.2:54321\r\n\(extra)Content-Length: \(body.count)\r\n\r\n".utf8) + body
}
let utf8Body = Data("{\"text\":\"مرحبا 👋 café\"}".utf8)
let request = try HTTPRequest.parse(wire(method: "POST", body: utf8Body))!
check(request.body == utf8Body, "UTF-8 body preserved byte for byte")
check(try HTTPRequest.parse(Data("GET / HTTP/1.1\r\n".utf8)) == nil, "Incomplete header waits")
let complete = wire(method: "POST", body: utf8Body)
for end in 1..<complete.count {
    let parsed = try HTTPRequest.parse(Data(complete.prefix(end)))
    check(parsed == nil, "Fragmented requests never execute prematurely")
}
rejects("Duplicate Host") { _ = try HTTPRequest.parse(wire("Host: evil.example\r\n")) }
rejects("Duplicate Content-Length") { _ = try HTTPRequest.parse(wire("Content-Length: 0\r\n")) }
rejects("Chunked") { _ = try HTTPRequest.parse(wire("Transfer-Encoding: chunked\r\n")) }
rejects("Leading header whitespace") { _ = try HTTPRequest.parse(wire(" X-Test: bad\r\n")) }
rejects("Negative length") { _ = try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nHost: test\r\nContent-Length: -1\r\n\r\n".utf8)) }
rejects("Pipelined") { _ = try HTTPRequest.parse(wire() + wire()) }
rejects("Header size") { _ = try HTTPRequest.parse(Data(repeating: 65, count: 8193)) }
rejects("Body size") { _ = try HTTPRequest.parse(Data(repeating: 65, count: 73729)) }
rejects("GET with body") { _ = try HTTPRequest.parse(wire(body: Data([65]))) }
for ip in ["10.0.0.2", "172.16.0.1", "172.31.255.254", "192.168.1.1"] {
    check(AccessPolicy.isPrivateIPv4(ip), "Private IPv4 accepted: \(ip)")
}
for ip in ["8.8.8.8", "127.0.0.1", "0.0.0.0", "172.15.1.1", "172.32.1.1", "192.168.1.256", "10.00.0.1", "::1", "169.254.0.2"] {
    check(!AccessPolicy.isPrivateIPv4(ip), "Non-private/invalid IPv4 rejected: \(ip)")
}
let host = "192.168.1.2:54321"
let token = String(repeating: "a", count: 64)
let client = String(repeating: "b", count: 32)
let headers = ["host": host, "authorization": "Bearer " + token, "x-client-id": client,
               "origin": "http://" + host, "content-type": "application/json"]
func auth(_ changes: [String: String]) throws {
    let r = HTTPRequest(method: "POST", path: "/api/send", headers: headers.merging(changes) { _, b in b }, body: Data())
    _ = try AccessPolicy.authorize(r, host: host, secret: token)
}
try auth([:]); checks += 1
rejects("Wrong origin") { try auth(["origin": "https://evil.example"]) }
rejects("Null origin") { try auth(["origin": "null"]) }
rejects("Wrong Host / rebinding") { try auth(["host": "evil.example:54321"]) }
rejects("Wrong token") { try auth(["authorization": "Bearer nope"]) }
rejects("Form post") { try auth(["content-type": "application/x-www-form-urlencoded"]) }
rejects("Wrong client shape") { try auth(["x-client-id": "short"]) }
try AccessPolicy.validateText("Hello 👋\nWorld\t!"); checks += 1
rejects("Empty text") { try AccessPolicy.validateText(" \n\t") }
rejects("Escape/control input") { try AccessPolicy.validateText("hello\u{001b}") }
rejects("Excessive text") { try AccessPolicy.validateText(String(repeating: "a", count: 12001)) }
check(AccessPolicy.constantTimeEqual(token, token), "Token matches")
check(!AccessPolicy.constantTimeEqual(token, String(repeating: "b", count: 64)), "Token mismatch")
var ledger = DeliveryLedger(limit: 1)
let id = String(repeating: "c", count: 32)
let receipt = HTTPResponse.json(200, ["id": id, "result": "clipboard"])
check(try ledger.lookup(id, fingerprint: "one") == nil, "New send is not duplicate")
ledger.record(id, fingerprint: "one", response: receipt)
check(try ledger.lookup(id, fingerprint: "one")?.body == receipt.body, "Retry returns original receipt")
rejects("ID reused with other text") { _ = try ledger.lookup(id, fingerprint: "two") }
rejects("No eviction at capacity") { _ = try ledger.lookup(String(repeating: "d", count: 32), fingerprint: "three") }
check(try ledger.lookup(id, fingerprint: "one") != nil, "Old retry remains recognized at capacity")
let response = String(data: receipt.encoded, encoding: .utf8)!
check(response.contains("Cache-Control: no-store"), "No caching")
check(response.contains("frame-ancestors 'none'"), "No framing")
check(!response.contains("Access-Control-Allow-Origin"), "No CORS opt-in")
print("PASS: \(checks) protocol, policy, Unicode and duplicate-receipt checks")
