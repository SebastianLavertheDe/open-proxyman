import Foundation
import zlib

struct WebSocketDeflate: Sendable {
    let windowBits: Int32
    let noContextTakeover: Bool

    /// Unlike preview decoding, interception must understand every negotiated extension.
    /// Unknown extensions can change the frame payload and cannot safely be re-encoded.
    static func scriptingIssue(in headers: HTTPHeaders) -> String? {
        let extensions = headers.values(of: "Sec-WebSocket-Extensions").flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
        guard !extensions.isEmpty else { return nil }
        guard extensions.count == 1 else { return "不支持同时协商多个 WebSocket 扩展" }
        let parts = extensions[0].split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.first == "permessage-deflate" else { return "不支持的 WebSocket 扩展：\(parts.first ?? "")" }
        var seen: Set<String> = []
        for parameter in parts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let key = pair.first, seen.insert(key).inserted else { return "WebSocket 压缩参数重复" }
            switch key {
            case "client_no_context_takeover", "server_no_context_takeover":
                guard pair.count == 1 else { return "WebSocket 压缩参数无效：\(key)" }
            case "client_max_window_bits", "server_max_window_bits":
                guard pair.count == 2, let bits = Int(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))),
                      (8...15).contains(bits) else { return "WebSocket 压缩窗口无效：\(key)" }
            default: return "不支持的 WebSocket 压缩参数：\(key)"
            }
        }
        return nil
    }

    static func negotiated(in headers: HTTPHeaders, direction: WSFrame.Direction) -> WebSocketDeflate? {
        let extensions = headers.values(of: "Sec-WebSocket-Extensions").flatMap { $0.split(separator: ",") }
        for item in extensions {
            let parts = item.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.first == "permessage-deflate" else { continue }
            let side = direction == .upstream ? "client" : "server"
            var window: Int32 = 15
            for parameter in parts.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pair.first == "\(side)_max_window_bits" {
                    guard pair.count == 2, let bits = Int32(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))),
                          (8...15).contains(bits) else { return nil }
                    window = bits
                }
            }
            return WebSocketDeflate(windowBits: window, noContextTakeover: parts.contains("\(side)_no_context_takeover"))
        }
        return nil
    }

    func recoverPreviews(for frames: [WSFrame], wire: Data, direction: WSFrame.Direction) -> [WSFrame] {
        let decoder = Decoder(self)
        var parser = WSFrameParser()
        var updated = frames
        var index = 0
        var remainingPreviewBytes = 8 * 1024 * 1024
        for offset in stride(from: wire.startIndex, to: wire.endIndex, by: 64 * 1024) {
            guard !Task.isCancelled, index < frames.count else { break }
            let chunk = wire[offset..<min(offset + 64 * 1024, wire.endIndex)]
            let parsed = parser.feed(chunk, direction: direction, limit: frames.count - index)
            for message in parsed {
                // Older captures lack RSV1. Only attach results when the re-parsed wire
                // bytes match the saved message in the same position.
                guard message.opcode == frames[index].opcode, message.payload == frames[index].payload else { return updated }
                updated[index].rsv1 = message.rsv1
                if message.rsv1 == true, remainingPreviewBytes > 0,
                   let preview = decoder.preview(message.payload) {
                    let count = min(preview.data.count, remainingPreviewBytes)
                    updated[index].decompressedPreview = Data(preview.data.prefix(count))
                    updated[index].decompressedPreviewTruncated = preview.truncated || count < preview.data.count
                    remainingPreviewBytes -= count
                }
                index += 1
            }
        }
        return updated
    }

    func fullMessage(_ target: WSFrame, in frames: [WSFrame]) -> Data? {
        let decoder = Decoder(self)
        if !noContextTakeover {
            // The selected message can reference previous compressed messages from its sender.
            // Only keep their sliding window while replaying them.
            for frame in frames where frame.direction == target.direction {
                if frame.id == target.id { break }
                guard !Task.isCancelled, let compressed = frame.rsv1 else { return nil }
                if compressed, decoder.preview(frame.payload, retaining: 0) == nil { return nil }
            }
        }
        guard !Task.isCancelled,
              let decoded = decoder.preview(target.payload, retaining: Int.max), !decoded.truncated else { return nil }
        return decoded.data
    }

    /// Owns the sliding window for one direction of a WebSocket connection.
    final class Decoder {
        private static let maxExpandedBytes = 8 * 1024 * 1024
        private let configuration: WebSocketDeflate
        private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        private var initialized = false
        private var lostContext = false

        init(_ configuration: WebSocketDeflate) {
            self.configuration = configuration
            stream.initialize(to: z_stream())
        }

        deinit {
            if initialized { inflateEnd(stream) }
            stream.deinitialize(count: 1)
            stream.deallocate()
        }

        func preview(_ payload: Data, retaining limit: Int = 256 * 1024) -> (data: Data, truncated: Bool)? {
            guard !lostContext, !payload.isEmpty, payload.count <= Int(uInt.max) - 4 else { return nil }
            if !initialized {
                initialized = inflateInit2_(stream, -configuration.windowBits, ZLIB_VERSION,
                                            Int32(MemoryLayout<z_stream>.size)) == Z_OK
                guard initialized else { return nil }
            } else if configuration.noContextTakeover {
                guard inflateReset(stream) == Z_OK else { return nil }
            }

            let result = inflateMessage(payload, retaining: max(0, limit))
            if result == nil && !configuration.noContextTakeover { lostContext = true }
            return result
        }

        private func inflateMessage(_ payload: Data, retaining limit: Int) -> (data: Data, truncated: Bool)? {
            // The sender strips the final four bytes of the Z_SYNC_FLUSH marker (RFC 7692 §7.2.2).
            var input = payload
            input.append(contentsOf: [0, 0, 0xff, 0xff])
            var output = Data()
            var expanded = 0
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            return input.withUnsafeBytes { bytes in
                stream.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
                stream.pointee.avail_in = uInt(bytes.count)
                defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
                while true {
                    let before = stream.pointee.avail_in
                    let unusedBits = stream.pointee.data_type & 63
                    let status = chunk.withUnsafeMutableBufferPointer { buffer in
                        stream.pointee.next_out = buffer.baseAddress
                        stream.pointee.avail_out = uInt(buffer.count)
                        return inflate(stream, Z_BLOCK)
                    }
                    let produced = chunk.count - Int(stream.pointee.avail_out)
                    expanded += produced
                    guard expanded <= Self.maxExpandedBytes else { return nil }
                    output.append(contentsOf: chunk.prefix(min(produced, limit - output.count)))

                    if status == Z_STREAM_END {
                        // A BFINAL block may appear before the empty flush block. Keep the history
                        // so later blocks and messages can still use its back-references.
                        guard stream.pointee.avail_in > 0, resetKeepingWindow() else { return nil }
                        continue
                    }
                    guard status == Z_OK else { return nil }
                    let atBlockEnd = stream.pointee.data_type & 128 != 0
                    let isByteAligned = stream.pointee.data_type & 63 == 0
                    if stream.pointee.avail_in == 0, atBlockEnd, isByteAligned {
                        return (output, expanded > output.count)
                    }
                    guard before != stream.pointee.avail_in || produced > 0 || unusedBits != stream.pointee.data_type & 63 else {
                        return nil
                    }
                }
            }
        }

        private func resetKeepingWindow() -> Bool {
            var dictionary = [UInt8](repeating: 0, count: 1 << Int(configuration.windowBits))
            return dictionary.withUnsafeMutableBufferPointer { buffer in
                var count: uInt = 0
                let next = stream.pointee.next_in
                let remaining = stream.pointee.avail_in
                guard inflateGetDictionary(stream, buffer.baseAddress, &count) == Z_OK,
                      inflateReset(stream) == Z_OK,
                      inflateSetDictionary(stream, buffer.baseAddress, count) == Z_OK else { return false }
                stream.pointee.next_in = next
                stream.pointee.avail_in = remaining
                return true
            }
        }
    }

    /// A distinct outbound dictionary is essential after a script modifies or drops a message.
    /// Reusing the sender's compressed bytes would reference history the receiver never saw.
    final class Encoder {
        private let configuration: WebSocketDeflate
        private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        private var initialized = false

        init(_ configuration: WebSocketDeflate) {
            self.configuration = configuration
            stream.initialize(to: z_stream())
        }

        deinit {
            if initialized { deflateEnd(stream) }
            stream.deinitialize(count: 1)
            stream.deallocate()
        }

        func encode(_ payload: Data) -> Data? {
            guard payload.count <= Int(uInt.max) else { return nil }
            if !initialized {
                // zlib cannot encode an 8-bit raw window. Literal-only Huffman coding
                // uses no distance references and is valid for the negotiated 8-bit window.
                let bits = max(9, configuration.windowBits)
                let strategy = configuration.windowBits == 8 ? Z_HUFFMAN_ONLY : Z_DEFAULT_STRATEGY
                initialized = deflateInit2_(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -bits, 8, strategy,
                                           ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
                guard initialized else { return nil }
            } else if configuration.noContextTakeover {
                guard deflateReset(stream) == Z_OK else { return nil }
            }
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let success = payload.withUnsafeBytes { bytes -> Bool in
                stream.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
                stream.pointee.avail_in = uInt(bytes.count)
                defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
                repeat {
                    let status = chunk.withUnsafeMutableBufferPointer { buffer in
                        stream.pointee.next_out = buffer.baseAddress
                        stream.pointee.avail_out = uInt(buffer.count)
                        return deflate(stream, Z_SYNC_FLUSH)
                    }
                    guard status == Z_OK else { return false }
                    output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.pointee.avail_out)))
                } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
                return true
            }
            guard success, output.suffix(4) == Data([0, 0, 0xff, 0xff]) else { return nil }
            output.removeLast(4)
            return output
        }
    }
}
