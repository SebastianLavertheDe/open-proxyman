import Compression
import Foundation

enum BrotliBody {
    enum DecodeError: Error, Equatable {
        case invalidStream
        case outputLimit
    }

    static let maxDecodedBytes = 32 * 1024 * 1024

    static func decode(_ data: Data, limit: Int = maxDecodedBytes, allowTruncatedOutput: Bool = false) throws -> Data {
        guard !data.isEmpty else { throw DecodeError.invalidStream }
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        return try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            try chunk.withUnsafeMutableBufferPointer { output in
                let source = input.bindMemory(to: UInt8.self)
                var stream = compression_stream(dst_ptr: output.baseAddress!, dst_size: 0,
                                                src_ptr: source.baseAddress!, src_size: 0, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
                    == COMPRESSION_STATUS_OK else { throw DecodeError.invalidStream }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = source.baseAddress!
                stream.src_size = source.count
                var decoded = Data()
                while true {
                    try Task.checkCancellation()
                    stream.dst_ptr = output.baseAddress!
                    stream.dst_size = output.count
                    let previousInput = stream.src_size
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let written = output.count - stream.dst_size
                    if written > max(0, limit) - decoded.count {
                        guard allowTruncatedOutput else { throw DecodeError.outputLimit }
                        decoded.append(output.baseAddress!, count: max(0, limit) - decoded.count)
                        return decoded
                    }
                    decoded.append(output.baseAddress!, count: written)
                    if status == COMPRESSION_STATUS_END, stream.src_size == 0 { return decoded }
                    guard status == COMPRESSION_STATUS_OK, written > 0 || stream.src_size < previousInput else {
                        throw DecodeError.invalidStream
                    }
                }
            }
        }
    }
}
