import Foundation

extension WSFrame {
    static var localizedUnavailablePreview: String { Strings.WebSocket.unavailablePreview }

    var localizedDirectionGlyph: String {
        direction == .upstream ? Strings.WebSocket.directionSend : Strings.WebSocket.directionReceive
    }

    var localizedOpcodeName: String {
        switch kind {
        case .text: return Strings.WebSocket.opcodeText
        case .binary: return Strings.WebSocket.opcodeBinary
        case .ping: return "Ping"
        case .pong: return "Pong"
        case .close: return Strings.WebSocket.opcodeClose
        case .continuation: return Strings.WebSocket.opcodeContinuation
        case .other: return Strings.WebSocket.opcodeOther(String(opcode, radix: 16))
        }
    }

    /// 数据与历史诊断不改写，只把本应用生成的预览占位说明本地化。
    var localizedPreviewText: String {
        if kind == .close {
            guard payload.count >= 2 else { return Strings.WebSocket.connectionClosed }
            let code = (UInt16(payload[0]) << 8) | UInt16(payload[1])
            return Strings.WebSocket.closeStatus(Int(code), Self.localizedCloseReason(code))
        }
        guard let body = displayPayload else { return Self.localizedUnavailablePreview }
        guard Self.utf8Preview(body, limit: 2048, alreadyTruncated: decompressedPreviewTruncated == true) != nil else {
            return Strings.WebSocket.binaryBytes(body.count)
        }
        return previewText
    }

    private static func localizedCloseReason(_ code: UInt16) -> String {
        switch code {
        case 1000: return Strings.WebSocket.closeNormal
        case 1001: return Strings.WebSocket.closeGoingAway
        case 1002: return Strings.WebSocket.closeProtocolError
        case 1003: return Strings.WebSocket.closeUnsupportedData
        case 1005: return Strings.WebSocket.closeNoStatus
        case 1006: return Strings.WebSocket.closeAbnormal
        case 1008: return Strings.WebSocket.closePolicyViolation
        case 1009: return Strings.WebSocket.closeMessageTooBig
        case 1011: return Strings.WebSocket.closeServerError
        default: return Strings.WebSocket.closeCode(Int(code))
        }
    }
}
