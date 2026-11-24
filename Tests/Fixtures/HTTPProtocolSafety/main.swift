import Foundation
import ProxyMirrorFoundation

@main
struct HTTPProtocolSafetyChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        func rejects(_ operation: () throws -> Void, _ message: String) {
            do { try operation(); preconditionFailure(message) }
            catch { count += 1 }
        }
        let invalid = [
            "Content-Length: 1\r\nContent-Length: 2", "Content-Length: 1, 2", "Content-Length: +1",
            "Content-Length: -1", "Content-Length: 9223372036854775808", "Content-Length:",
            "Transfer-Encoding: chunked\r\nContent-Length: 0", "Transfer-Encoding: chunked, gzip",
            "Transfer-Encoding: chunked, chunked", "Transfer-Encoding: chunkedness", "Transfer-Encoding: chunked; key=value",
            "Transfer-Encoding: gzip", "Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked, gzip",
            "Content-Length : 0", "Content-Length: 0\r\n folded", "Bad Header: x", "Bad-Header",
            "Host: one.test\r\nHost: two.test", "X-Test: a\u{00}b",
        ]
        for headers in invalid {
            rejects({ _ = try RequestHeadParser.parse("POST / HTTP/1.1\r\nHost: fixture.test\r\n" + headers) }, headers)
        }
        for headers in invalid.filter({ !$0.hasPrefix("Host:") && !["Transfer-Encoding: gzip", "Transfer-Encoding: chunkedness"].contains($0) }) {
            rejects({ _ = try ResponseHeadParser.parse("HTTP/1.1 200 OK\r\n" + headers) }, "response: " + headers)
        }
        var accepted = try RequestHeadParser.parse("POST / HTTP/1.1\r\nContent-Length: 05, 5\r\nContent-Length: 5")
        check(accepted.headers.values(of: "Content-Length") == ["5"], "Equal lengths normalize to a single decimal field")
        check(try HTTPFraming.request(&accepted) == .fixed(5), "Body tracker uses the normalized length")
        let combined = try RequestHeadParser.parse("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked")
        check(combined.headers.values(of: "Transfer-Encoding") == ["gzip, chunked"], "TE list order survives combining")
        let extensionCoding = try RequestHeadParser.parse("POST / HTTP/1.1\r\nTransfer-Encoding: X-Extension; key=\"A,b\", chunked")
        check(extensionCoding.headers.value(of: "Transfer-Encoding") == "x-extension; key=\"A,b\", chunked", "Transfer parameters preserve quoted commas and case")
        let lowerMethod = try RequestHeadParser.parse("custom / HTTP/1.1")
        check(lowerMethod.method == "custom", "Case-sensitive extension methods survive parsing")
        let absolute = try RequestHeadParser.parse("GET http://allowed.test:8080/x HTTP/1.1\r\nHost: other.test")
        check(absolute.headers.value(of: "Host") == "allowed.test:8080", "Absolute authority replaces a conflicting Host before routing")
        let ipv6 = try RequestHeadParser.parse("GET https://[::1]:9443/x HTTP/1.1\r\nHost: other.test")
        check(ipv6.headers.value(of: "Host") == "[::1]:9443", "IPv6 Host retains its authority syntax")
        let origin = try RequestHeadParser.parse("GET /x HTTP/1.1\r\nHost: original.test:8081")
        check(origin.headers.value(of: "Host") == "original.test:8081", "Origin-form Host remains the target")
        for target in ["http://user:password@fixture.test/x", "http://fixture.test:0/x", "http://fixture.test:65536/x", "http://fixture.test/x#fragment"] {
            rejects({ _ = try RequestHeadParser.parse("GET \(target) HTTP/1.1\r\nHost: fixture.test") }, target)
        }
        check(URLParser.parse(target: "http://fixture.test/x#fragment")?.path == "/x", "General URL parsing still accepts application URL fragments")
        check(URLParser.parse(target: "http://user:password@fixture.test/x")?.host == "fixture.test", "General URL parsing preserves Compose userinfo support")
        let wire = try sanitizedRequestHead(head: accepted, originFormTarget: "/", keepAlive: true)
        var parser = RequestHeadParser()
        check(try parser.feed(wire)?.headers.values(of: "Content-Length") == ["5"], "Forwarded framing round trips")
        var response = ResponseHeadParser()
        check(try response.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 2,2\r\n\r\nokNEXT".utf8))?.headers.value(of: "Content-Length") == "2",
              "Response lengths are normalized before body tracking")
        check(response.trailing == Array("okNEXT".utf8), "Normalization does not consume pipelined bytes")
        var trailer = ChunkedTracker()
        rejects({ _ = try trailer.consume(Data("0\r\nContent-Length: 7\r\n\r\n".utf8)) }, "Framing cannot appear in trailers")
        var policy = HTTPTransferTimeoutPolicy(interval: 30, now: 0)
        for second in stride(from: 5, through: 45, by: 5) {
            policy.uploaded(at: Double(second))
            check(policy.deadline(requestPending: true, responseStarted: false, eventStream: false)! > Double(second),
                  "Continuing upload has a fresh progress deadline")
        }
        check(policy.deadline(requestPending: false, responseStarted: false, eventStream: false) == 75,
              "Response wait begins after the final upload bytes")
        check(policy.deadline(requestPending: true, responseStarted: false, eventStream: false) == 75,
              "A stalled upload still has a deadline")
        policy.downloaded(at: 60)
        check(policy.deadline(requestPending: false, responseStarted: true, eventStream: false) == 90,
              "Ordinary response bodies have a read-progress timeout")
        check(policy.deadline(requestPending: false, responseStarted: true, eventStream: true) == nil,
              "An established SSE stream can remain silent")
        check(policy.deadline(requestPending: false, responseStarted: false, eventStream: true) == 90,
              "An event-stream request still times out before response headers")
        print("PASS: \(count) production HTTP parser, framing, authority and timeout checks")
    }
}
