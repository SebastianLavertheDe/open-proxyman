import Foundation

enum RequestCode {
    private static let transportHeaders: Set<String> = [
        "connection", "content-length", "host", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade"
    ]
    private static let browserHeaders: Set<String> = [
        "accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
        "cookie", "cookie2", "date", "dnt", "expect", "origin", "referer", "set-cookie", "set-cookie2", "via"
    ]

    static func pythonRequests(_ tx: Transaction, redactSensitiveHeaders: Bool? = nil) -> String {
        let request = ComposeService.request(from: tx)
        let headers = replayHeaders(request.headers, redactSensitiveHeaders: redactSensitiveHeaders)
        let pairs = headers.map { field in
            let value = quoted(field.value) + (field.value.utf8.allSatisfy { $0 < 128 } ? "" : ".encode(\"utf-8\")")
            return "    (\(quoted(field.name)), \(value)),"
        }
        var lines = ["import requests", "from urllib3._collections import HTTPHeaderDict"]
        if request.body != nil { lines.insert("from base64 import b64decode", at: 0) }
        lines += ["", "request = requests.Request(", "    method=\(quoted(request.method)),",
                  "    url=\(quoted(request.url)),"]
        if let body = request.body {
            lines.append("    data=b64decode(\(quoted(body.base64EncodedString()))),")
        }
        lines += [").prepare()", "headers = HTTPHeaderDict(["] + pairs + [
            "])",
            "for name, value in request.headers.items():",
            "    if name not in headers:",
            "        headers.add(name, value)",
            "request.headers = headers",
            "",
            "with requests.Session() as session:",
            "    response = session.send(request, timeout=30, allow_redirects=False)",
            "print(response.status_code)"
        ]
        return lines.joined(separator: "\n")
    }

    static func supportsFetch(_ tx: Transaction) -> Bool {
        let method = tx.method.uppercased()
        guard tx.canReplay, !["CONNECT", "TRACE", "TRACK"].contains(method) else { return false }
        return !["GET", "HEAD"].contains(method) || tx.requestBody.isEmpty
    }

    static func javascriptFetch(_ tx: Transaction, redactSensitiveHeaders: Bool? = nil) -> String {
        let request = ComposeService.request(from: tx)
        let capturedHeaders = replayHeaders(request.headers, redactSensitiveHeaders: redactSensitiveHeaders)
        let headers = capturedHeaders.filter { field in
            let name = field.name.lowercased()
            return !browserHeaders.contains(name) && !name.hasPrefix("sec-") && !name.hasPrefix("proxy-")
                && !(["x-http-method", "x-http-method-override", "x-method-override"].contains(name)
                    && field.value.split(separator: ",").contains {
                        ["CONNECT", "TRACE", "TRACK"].contains($0.trimmingCharacters(in: .whitespaces).uppercased())
                    })
        }
        let needsEncoding = headers.contains { !$0.value.utf8.allSatisfy { $0 < 128 } }
        var lines: [String] = []
        if capturedHeaders.count != headers.count {
            lines.append("// The browser generates restricted headers such as Cookie and Origin for its current context.")
        }
        if Set(headers.map { $0.name.lowercased() }).count != headers.count {
            lines.append("// Fetch combines duplicate request header values.")
        }
        if needsEncoding {
            lines.append("const utf8Header = (value) => Array.from(new TextEncoder().encode(value),")
            lines.append("  (byte) => String.fromCharCode(byte)).join(\"\");")
        }
        lines += ["fetch(\(quoted(request.url)), {", "  method: \(quoted(request.method)),", "  headers: ["]
        for field in headers {
            let literal = quoted(field.value)
            let value = field.value.utf8.allSatisfy { $0 < 128 } ? literal : "utf8Header(\(literal))"
            lines.append("    [\(quoted(field.name)), \(value)],")
        }
        lines += ["  ],"]
        if let body = request.body {
            let base64 = quoted(body.base64EncodedString())
            lines.append("  body: Uint8Array.from(atob(\(base64)), (byte) => byte.charCodeAt(0)),")
        }
        lines += ["  redirect: \"manual\",", "}).then((response) => console.log(response.status));"]
        return lines.joined(separator: "\n")
    }

    private static func replayHeaders(_ headers: [(String, String)], redactSensitiveHeaders: Bool? = nil) -> [(name: String, value: String)] {
        let connectionFields = headers.filter { $0.0.caseInsensitiveCompare("Connection") == .orderedSame }
            .flatMap { $0.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        let omitted = transportHeaders.union(connectionFields)
        let punctuation = Set("!#$%&'*+-.^`|~_".utf8)
        return ExportRedaction.headers(headers, redact: redactSensitiveHeaders ?? AppSettings.shared.redactSensitiveHeaders).filter { name, value in
            !name.isEmpty && !omitted.contains(name.lowercased()) && name.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || punctuation.contains($0)
            } && value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
        }
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding a Swift string always produces a quoted JSON string, accepted by both languages.
        return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}

extension RequestCode {
    enum Format: String, CaseIterable, Identifiable {
        case curl, httpie, python, fetch
        case swift, alamofire, moya, go, nodeHTTP, axios, got, nodeRequest, jquery
        case kotlin, java, dart, php, rust, objectiveC, har, postman
        var id: String { rawValue }
        var title: String {
            switch self {
            case .curl: return "cURL"
            case .httpie: return "HTTPie"
            case .python: return "Python requests"
            case .fetch: return "JavaScript fetch"
            case .swift: return "Swift URLSession"
            case .alamofire: return "Swift Alamofire"
            case .moya: return "Swift Moya"
            case .go: return "Go net/http"
            case .nodeHTTP: return "Node.js http/https"
            case .axios: return "Node.js Axios"
            case .got: return "Node.js Got"
            case .nodeRequest: return "Node.js request (legacy)"
            case .jquery: return "jQuery AJAX"
            case .kotlin: return "Kotlin OkHttp"
            case .java: return "Java HttpClient"
            case .dart: return "Dart HttpClient"
            case .php: return "PHP cURL"
            case .rust: return "Rust reqwest"
            case .objectiveC: return "Objective-C NSURLSession"
            case .har: return "HAR 1.2"
            case .postman: return "Postman Collection"
            }
        }
    }

    static func supported(_ format: Format, for tx: Transaction) -> Bool {
        if [.har, .postman].contains(format) { return true }
        if [.fetch, .jquery].contains(format) { return supportsFetch(tx) }
        if [.kotlin, .alamofire, .moya].contains(format), ["GET", "HEAD"].contains(tx.method.uppercased()), !tx.requestBody.isEmpty { return false }
        return tx.canReplay
    }

    static func generate(_ tx: Transaction, format: Format, runtime: ProxyRuntimeContext? = nil) -> String {
        let request = ComposeService.request(from: tx)
        let headers = replayHeaders(request.headers, redactSensitiveHeaders: runtime?.redactSensitiveHeaders)
        let url = quoted(request.url), method = quoted(request.method)
        let base64 = quoted((request.body ?? Data()).base64EncodedString())
        let groupedHeaders = mergedHeaders(headers)
        let pairs = groupedHeaders.map { "[\(quoted($0.name)), \(quoted($0.value))]" }.joined(separator: ", ")
        let object = "{" + groupedHeaders.map { "\(quoted($0.name)): \(quoted($0.value))" }.joined(separator: ", ") + "}"
        let duplicateNote = groupedHeaders.count == headers.count ? "" : "// This client combines repeated header values. Use native Node.js http/https or Go for separate header fields.\n"
        let swiftHeaders = groupedHeaders.isEmpty ? "[:]" : "[" + groupedHeaders.map { "\(swiftLiteral($0.name)): \(swiftLiteral($0.value))" }.joined(separator: ", ") + "]"
        switch format {
        case .curl: return ExportService.curlCommand(tx, runtime: runtime ?? .shared)
        case .httpie: return ExportService.httpieCommand(tx, runtime: runtime ?? .shared)
        case .python: return pythonRequests(tx, redactSensitiveHeaders: runtime?.redactSensitiveHeaders)
        case .fetch: return javascriptFetch(tx, redactSensitiveHeaders: runtime?.redactSensitiveHeaders)
        case .swift:
            return """
            import Foundation
            var request = URLRequest(url: URL(string: \(swiftLiteral(request.url)))!)
            request.httpMethod = \(swiftLiteral(request.method))
            \(headers.map { "request.addValue(\(swiftLiteral($0.value)), forHTTPHeaderField: \(swiftLiteral($0.name)))" }.joined(separator: "\n"))
            \(request.body == nil ? "" : "request.httpBody = Data(base64Encoded: \(base64))!")
            let (data, response) = try await URLSession.shared.data(for: request)
            print((response as? HTTPURLResponse)?.statusCode ?? 0)
            print(String(decoding: data, as: UTF8.self))
            """
        case .alamofire:
            return duplicateNote + """
            import Foundation
            import Alamofire
            let headers = HTTPHeaders([\(groupedHeaders.map { "HTTPHeader(name: \(swiftLiteral($0.name)), value: \(swiftLiteral($0.value)))" }.joined(separator: ", "))])
            let data = Data(base64Encoded: \(base64))!
            AF.upload(data, to: \(swiftLiteral(request.url)), method: HTTPMethod(rawValue: \(swiftLiteral(request.method))), headers: headers)
                .responseData { response in print(response) }
            """
        case .moya:
            return duplicateNote + """
            import Foundation
            import Moya
            struct CapturedRequest: TargetType {
                let baseURL = URL(string: \(swiftLiteral(request.url)))!
                let path = ""
                let method = Moya.Method(rawValue: \(swiftLiteral(request.method)))
                let sampleData = Data()
                let task = \(request.body == nil ? "Task.requestPlain" : "Task.requestData(Data(base64Encoded: \(base64))!)")
                let headers: [String: String]? = \(swiftHeaders)
            }
            let provider = MoyaProvider<CapturedRequest>()
            provider.request(CapturedRequest()) { result in print(result) }
            """
        case .go:
            return """
            package main
            import ("bytes"; "encoding/base64"; "fmt"; "io"; "net/http"; "time")
            func main() {
                body, err := base64.StdEncoding.DecodeString(\(base64)); if err != nil { panic(err) }
                req, err := http.NewRequest(\(method), \(url), bytes.NewReader(body)); if err != nil { panic(err) }
                \(headers.map { "req.Header.Add(\(quoted($0.name)), \(quoted($0.value)))" }.joined(separator: "\n    "))
                client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
                resp, err := client.Do(req); if err != nil { panic(err) }; defer resp.Body.Close()
                data, err := io.ReadAll(resp.Body); if err != nil { panic(err) }
                fmt.Println(resp.StatusCode); fmt.Println(string(data))
            }
            """
        case .nodeHTTP:
            return """
            const http = require(\(quoted(request.url.hasPrefix("https:") ? "node:https" : "node:http")));
            const body = Buffer.from(\(base64), "base64");
            const headers = ["Host", new URL(\(url)).host, \(headers.flatMap { [quoted($0.name), quoted($0.value)] }.joined(separator: ", "))];
            \(request.body == nil ? "" : "headers.push(\"Content-Length\", String(body.length));")
            const request = http.request(\(url), { method: \(method), headers }, response => {
              console.log(response.statusCode); response.pipe(process.stdout);
            });
            request.setTimeout(30000, () => request.destroy(new Error("Request timed out")));
            request.on("error", console.error);
            \(request.body == nil ? "request.end();" : "request.end(body);")
            """
        case .axios:
            return duplicateNote + """
            const axios = require("axios");
            axios({ url: \(url), method: \(method), headers: \(object),
              data: Buffer.from(\(base64), "base64"), timeout: 30000, maxRedirects: 0,
              responseType: "arraybuffer", validateStatus: () => true
            }).then(response => { console.log(response.status); process.stdout.write(Buffer.from(response.data)); }).catch(console.error);
            """
        case .got:
            return duplicateNote + """
            import got from "got";
            const response = await got(\(url), { method: \(method), headers: \(object),
              body: Buffer.from(\(base64), "base64"), allowGetBody: true, followRedirect: false, throwHttpErrors: false,
              timeout: { request: 30000 }, retry: { limit: 0 }, responseType: "buffer"
            });
            console.log(response.statusCode); process.stdout.write(response.body);
            """
        case .nodeRequest:
            return duplicateNote + """
            // The request package is deprecated; prefer native http/https, fetch or Axios for new projects.
            const request = require("request");
            request({ url: \(url), method: \(method), headers: \(object),
              body: Buffer.from(\(base64), "base64"), followRedirect: false, timeout: 30000, encoding: null
            }, (error, response, body) => { if (error) { console.error(error); return; } console.log(response.statusCode); process.stdout.write(body); });
            """
        case .jquery:
            return duplicateNote + """
            // Browser-controlled headers (Cookie, Origin, etc.) follow the current browser context.
            const forbidden = new Set(["cookie", "cookie2", "origin", "referer", "date", "accept-encoding", "user-agent"]);
            const headers = Object.fromEntries([\(pairs)].filter(([name]) => !forbidden.has(name.toLowerCase()) && !/^(sec-|proxy-)/i.test(name)));
            $.ajax({ url: \(url), method: \(method), headers, processData: false, contentType: false,
              \(request.body == nil ? "" : "data: Uint8Array.from(atob(\(base64)), c => c.charCodeAt(0)),")
              timeout: 30000, success: data => console.log(data), error: xhr => console.log(xhr.status, xhr.responseText)
            });
            """
        case .kotlin:
            return """
            import okhttp3.OkHttpClient
            import okhttp3.Request
            import okhttp3.RequestBody.Companion.toRequestBody
            import java.util.Base64
            import java.util.concurrent.TimeUnit
            fun main() {
                val client = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).followRedirects(false).build()
                val builder = Request.Builder().url(\(kotlinLiteral(request.url)))
                \(headers.map { "builder.addHeader(\(kotlinLiteral($0.name)), \(kotlinLiteral($0.value)))" }.joined(separator: "\n    "))
                val body = \(request.body == nil && ["GET", "HEAD"].contains(request.method) ? "null" : "Base64.getDecoder().decode(\(base64)).toRequestBody()")
                builder.method(\(kotlinLiteral(request.method)), body)
                client.newCall(builder.build()).execute().use { response -> println(response.code); println(response.body?.string()) }
            }
            """
        case .java:
            return """
            import java.net.URI;
            import java.net.http.*;
            import java.time.Duration;
            import java.util.Base64;
            public class CapturedRequest {
                public static void main(String[] args) throws Exception {
                    var client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build();
                    var builder = HttpRequest.newBuilder(URI.create(\(url))).timeout(Duration.ofSeconds(30));
                    \(headers.filter { $0.name.caseInsensitiveCompare("Expect") != .orderedSame }.map { "builder.header(\(quoted($0.name)), \(quoted($0.value)));" }.joined(separator: "\n        "))
                    \(headers.contains(where: { $0.name.caseInsensitiveCompare("Expect") == .orderedSame && $0.value.caseInsensitiveCompare("100-continue") == .orderedSame }) ? "builder.expectContinue(true);" : "")
                    builder.method(\(method), HttpRequest.BodyPublishers.ofByteArray(Base64.getDecoder().decode(\(base64))));
                    var response = client.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray());
                    System.out.println(response.statusCode()); System.out.write(response.body());
                }
            }
            """
        case .dart:
            return """
            import 'dart:io';
            import 'dart:convert';
            Future<void> main() async {
              final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
              try {
                final request = await client.openUrl(\(dartLiteral(request.method)), Uri.parse(\(dartLiteral(request.url))));
                request.followRedirects = false;
                \(headers.map { "request.headers.add(\(dartLiteral($0.name)), \(dartLiteral($0.value)));" }.joined(separator: "\n    "))
                request.add(base64Decode(\(base64)));
                final response = await request.close().timeout(const Duration(seconds: 30));
                print(response.statusCode); await stdout.addStream(response);
              } finally { client.close(force: true); }
            }
            """
        case .php:
            return """
            <?php
            $ch = curl_init(\(phpLiteral(request.url)));
            curl_setopt_array($ch, [CURLOPT_CUSTOMREQUEST => \(phpLiteral(request.method)),
              CURLOPT_HTTPHEADER => [\(headers.map { phpLiteral($0.name + ": " + $0.value) }.joined(separator: ", "))],
              CURLOPT_POSTFIELDS => base64_decode(\(base64)), CURLOPT_RETURNTRANSFER => true,
              CURLOPT_FOLLOWLOCATION => false, CURLOPT_TIMEOUT => 30]);
            $body = curl_exec($ch);
            if ($body === false) { throw new RuntimeException(curl_error($ch)); }
            echo curl_getinfo($ch, CURLINFO_RESPONSE_CODE), PHP_EOL, $body;
            curl_close($ch);
            """
        case .rust:
            return """
            // Cargo dependencies: reqwest = { version = "0.12", features = ["blocking"] }, base64 = "0.22"
            use base64::Engine;
            fn main() -> Result<(), Box<dyn std::error::Error>> {
                let client = reqwest::blocking::Client::builder().redirect(reqwest::redirect::Policy::none())
                    .timeout(std::time::Duration::from_secs(30)).build()?;
                let body = base64::engine::general_purpose::STANDARD.decode(\(base64))?;
                let mut request = client.request(reqwest::Method::from_bytes(\(swiftLiteral(request.method)).as_bytes())?, \(swiftLiteral(request.url)));
                \(headers.map { "request = request.header(\(swiftLiteral($0.name)), \(swiftLiteral($0.value)));" }.joined(separator: "\n    "))
                let response = request.body(body).send()?;
                println!("{}", response.status());
                std::io::Write::write_all(&mut std::io::stdout(), &response.bytes()?)?;
                Ok(())
            }
            """
        case .objectiveC:
            return """
            #import <Foundation/Foundation.h>
            int main(void) { @autoreleasepool {
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@\(url)]];
                request.HTTPMethod = @\(method);
                \(headers.map { "[request addValue:@\(quoted($0.value)) forHTTPHeaderField:@\(quoted($0.name))];" }.joined(separator: "\n    "))
                request.HTTPBody = [[NSData alloc] initWithBase64EncodedString:@\(base64) options:0];
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    NSLog(@"%@ %@", response, error);
                    if (data) fwrite(data.bytes, 1, data.length, stdout);
                    dispatch_semaphore_signal(done);
                }] resume];
                dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
            } return 0; }
            """
        case .har:
            return json(ExportService.buildHAR([tx], redactSensitiveHeaders: runtime?.redactSensitiveHeaders))
        case .postman:
            let body: [String: Any]
            if let bytes = request.body, let text = String(data: bytes, encoding: .utf8), !bytes.contains(0) {
                body = ["mode": "raw", "raw": text]
            } else if request.body != nil {
                // Postman accepts binary request bodies through a local file, not an inline base64 string.
                body = ["mode": "file", "file": ["src": "request-body.bin"]]
            } else { body = [:] }
            return json([
                "info": ["name": "ProxyMirror \(request.method) \(tx.host)",
                         "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
                         "description": request.body.map { "Binary body (if applicable): decode the following Base64 to request-body.bin before sending: " + $0.base64EncodedString() } ?? "Captured with ProxyMirror"],
                "item": [["name": request.method + " " + tx.path,
                          "request": ["method": request.method, "url": request.url,
                                      "header": headers.map { ["key": $0.name, "value": $0.value] }, "body": body]]],
            ])
        }
    }

    private static func mergedHeaders(_ headers: [(name: String, value: String)]) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for field in headers {
            if let index = result.firstIndex(where: { $0.name.caseInsensitiveCompare(field.name) == .orderedSame }) {
                let separator = field.name.caseInsensitiveCompare("Cookie") == .orderedSame ? "; " : ", "
                result[index].value += separator + field.value
            } else { result.append(field) }
        }
        return result
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    private static func swiftLiteral(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            case 0...31, 127, 0x2028, 0x2029: result += "\\u{" + String(scalar.value, radix: 16) + "}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
    private static func kotlinLiteral(_ value: String) -> String { quoted(value).replacingOccurrences(of: "$", with: "\\$") }
    private static func dartLiteral(_ value: String) -> String { quoted(value).replacingOccurrences(of: "$", with: "\\$") }
    private static func phpLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
