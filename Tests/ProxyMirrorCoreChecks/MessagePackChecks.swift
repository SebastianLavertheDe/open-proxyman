import Foundation
@testable import ProxyMirrorCore

/// G5：MessagePack 解码（base64 字节夹具；输出为保持键序的规范 JSON）
func checkMessagePack(_ test: CoreAssertions) {
    func b64(_ base64: String) -> Data { Data(base64Encoded: base64)! }
    func text(_ base64: String) -> String {
        guard let json = MessagePackBody.decodeIfMessagePack(b64(base64)) else { return "<nil>" }
        return String(decoding: json, as: UTF8.self)
    }
    func hinted(_ base64: String) -> String {
        guard let json = MessagePackBody.decodeIfMessagePack(b64(base64), contentTypeHint: "application/msgpack")
        else { return "<nil>" }
        return String(decoding: json, as: UTF8.self)
    }

    test.equal(text("h6bkuK3mloej5YC8pWNvdW50AqJwactADAAAAAAAAKJva8OjbmlswKR0YWdzkqFhoWKkYmxvYsQDAQID"), "{\"中文\":\"值\",\"count\":2,\"pi\":3.5,\"ok\":true,\"nil\":null,\"tags\":[\"a\",\"b\"],\"blob\":\"AQID\"}", "MessagePack: fixmap 全类型")
    test.equal(text("3gABoWsB"), "{\"k\":1}", "MessagePack: map16")
    test.equal(hinted("ykAAAAA="), "2.0", "MessagePack: float32 保留小数")
    test.equal(hinted("zf//"), "65535", "MessagePack: uint16")
    test.equal(hinted("0IA="), "-128", "MessagePack: int8 负数")

    test.expect(MessagePackBody.decodeIfMessagePack(b64("kAE=")) == nil, "MessagePack: 尾部残留拒绝")
    test.expect(MessagePackBody.decodeIfMessagePack(b64("kqFh")) == nil, "MessagePack: 元素数不足拒绝")
    test.expect(MessagePackBody.decodeIfMessagePack(b64("W10=")) == nil, "MessagePack: 合法 JSON 不转换")
    test.expect(MessagePackBody.decodeIfMessagePack(b64("aGVsbG8gd29ybGQ=")) == nil, "MessagePack: 非 map/array 根启发式拒绝")
    let hinted = MessagePackBody.decodeIfMessagePack(Data([0x01]), contentTypeHint: "application/msgpack")
    test.equal(String(decoding: hinted ?? Data(), as: UTF8.self), "1", "MessagePack: 内容类型提示时标量放行")
}
