import NIOCore

/// 从 TLS ClientHello 中嗅探 SNI 域名（用于 MITM 动态证书选择）。
/// 防御式解析：任何异常都返回 complete=true + sni=nil，不阻塞连接。
enum ClientHelloSniffer {

    struct Result {
        let complete: Bool
        let sni: String?
    }

    /// 每次喂入新数据后调用；返回解析进展。
    /// - buffer: 累积的原始字节（从 CONNECT 之后开始）
    static func parse(_ buffer: [UInt8]) -> Result {
        // TLS record header: type(1) version(2) length(2)
        guard buffer.count >= 5 else { return Result(complete: false, sni: nil) }
        guard buffer[0] == 0x16 else { return Result(complete: true, sni: nil) }   // 非 Handshake
        let recordLen = Int(buffer[3]) << 8 | Int(buffer[4])
        let recordTotal = 5 + recordLen
        guard buffer.count >= recordTotal else {
            if buffer.count > 32 * 1024 { return Result(complete: true, sni: nil) }
            return Result(complete: false, sni: nil)
        }
        let body = Array(buffer[5..<recordTotal])
        // Handshake: type(1) len(3)
        guard body.count >= 4, body[0] == 0x01 else { return Result(complete: true, sni: nil) }
        var offset = 4
        // client_version(2)
        offset += 2
        guard body.count >= offset else { return Result(complete: true, sni: nil) }
        // random(32)
        offset += 32
        guard body.count >= offset else { return Result(complete: true, sni: nil) }
        // session_id
        guard let p1 = readVector(body, offset: offset, lenBytes: 1) else {
            return Result(complete: true, sni: nil)
        }
        offset = p1.next
        // cipher_suites
        guard let p2 = readVector(body, offset: offset, lenBytes: 2) else {
            return Result(complete: true, sni: nil)
        }
        offset = p2.next
        // compression_methods
        guard let p3 = readVector(body, offset: offset, lenBytes: 1) else {
            return Result(complete: true, sni: nil)
        }
        offset = p3.next
        // extensions（可选）
        guard body.count >= offset + 2 else { return Result(complete: true, sni: nil) }
        let extTotal = Int(body[offset]) << 8 | Int(body[offset + 1])
        offset += 2
        let extEnd = min(offset + extTotal, body.count)

        var sni: String? = nil
        while offset + 4 <= extEnd {
            let extType = Int(body[offset]) << 8 | Int(body[offset + 1])
            let extLen = Int(body[offset + 2]) << 8 | Int(body[offset + 3])
            offset += 4
            let dataEnd = min(offset + extLen, extEnd)
            if extType == 0x0000, sni == nil {   // server_name
                sni = parseServerName(Array(body[offset..<dataEnd]))
            }
            offset = dataEnd
        }
        return Result(complete: true, sni: sni)
    }

    private static func readVector(_ bytes: [UInt8], offset: Int, lenBytes: Int) -> (next: Int, data: ArraySlice<UInt8>)? {
        guard bytes.count >= offset + lenBytes else { return nil }
        var length = 0
        for i in 0..<lenBytes {
            length = length << 8 | Int(bytes[offset + i])
        }
        let dataStart = offset + lenBytes
        guard bytes.count >= dataStart + length else { return nil }
        return (dataStart + length, bytes[dataStart..<(dataStart + length)])
    }

    /// server_name_list: totalLen(2) + [ type(1)=0 hostLen(2) host ]
    private static func parseServerName(_ list: [UInt8]) -> String? {
        guard list.count >= 2 else { return nil }
        let total = Int(list[0]) << 8 | Int(list[1])
        var offset = 2
        let end = min(2 + total, list.count)
        while offset + 3 <= end {
            let nameType = list[offset]
            let nameLen = Int(list[offset + 1]) << 8 | Int(list[offset + 2])
            offset += 3
            guard offset + nameLen <= end else { return nil }
            if nameType == 0 {
                let hostBytes = Array(list[offset..<(offset + nameLen)])
                return String(decoding: hostBytes, as: UTF8.self)
            }
            offset += nameLen
        }
        return nil
    }
}
