import Foundation

@main
struct ScriptFrameDecisionChecks {
    static func main() throws {
        var count = 0
        func check(_ json: String, _ expected: WSFrameAction?) throws {
            let value = try JSONDecoder().decode(FrameValue.self, from: Data(json.utf8))
            precondition(ScriptingService.interpretFrameValue(value) == expected, json)
            count += 1
        }
        try check("false", .drop)
        try check("true", nil)
        try check("null", nil)
        try check("{}", nil)
        try check(#"{"drop":true}"#, .drop)
        try check(#"{"drop":false}"#, nil)
        try check(#"{"drop":false,"body":"updated"}"#, .modify(payload: Data("updated".utf8), note: "text"))
        try check(#"{"action":"pass","drop":true}"#, .pass)
        try check(#"{"action":"drop","drop":false}"#, .drop)
        try check(#"{"action":"close","drop":false}"#, .close)
        try check(#"{"drop":false,"base64":"AQID"}"#, .modify(payload: Data([1, 2, 3]), note: "binary"))
        print("PASS: \(count) native Swift production frame-value decoder/action checks")
    }
}
