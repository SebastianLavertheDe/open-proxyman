import CoreFoundation
import Foundation

/// Pretty JSON emits one line at a time. The consumer owns the document/line
/// budget and can stop immediately; no complete pretty document is allocated.
package enum BoundedJSONWriter {
    package enum Failure: Error, Equatable { case lineLimit, unsupportedValue }

    package static func write(_ object: Any, maximumLineBytes: Int = 1_048_576,
                              append: (String) -> Bool,
                              cancelled: () -> Bool = { Task.isCancelled }) throws -> Bool {
        guard !cancelled() else { throw CancellationError() }
        var writer = Writer(lineLimit: max(0, maximumLineBytes))
        return try writer.write(object, depth: 0, prefix: "", suffix: "", append: append, cancelled: cancelled)
    }

    private struct Writer {
        let lineLimit: Int
        var work = 0

        mutating func checkpoint(_ cancelled: () -> Bool) throws {
            work += 1
            if work & 255 == 0, cancelled() { throw CancellationError() }
        }

        func emit(_ line: String, append: (String) -> Bool, cancelled: () -> Bool) throws -> Bool {
            guard !cancelled() else { throw CancellationError() }
            guard line.utf8.count <= lineLimit else { throw Failure.lineLimit }
            return append(line)
        }

        mutating func quoted(_ text: String, cancelled: () -> Bool) throws -> String {
            var output = Data([34])
            func append(_ bytes: some Collection<UInt8>) throws {
                guard bytes.count <= lineLimit - output.count else { throw Failure.lineLimit }
                output.append(contentsOf: bytes)
            }
            let bytes = text.utf8
            var start = bytes.startIndex, cursor = start
            while cursor < bytes.endIndex {
                try checkpoint(cancelled)
                let value = bytes[cursor]
                if value < 32 || value == 34 || value == 92 {
                    try append(bytes[start..<cursor])
                    switch value {
                    case 34: try append([92, 34])
                    case 92: try append([92, 92])
                    case 8: try append([92, 98])
                    case 9: try append([92, 116])
                    case 10: try append([92, 110])
                    case 12: try append([92, 102])
                    case 13: try append([92, 114])
                    default:
                        let digits = Array("0123456789abcdef".utf8)
                        try append([92, 117, 48, 48, digits[Int(value >> 4)], digits[Int(value & 15)]])
                    }
                    start = bytes.index(after: cursor)
                }
                cursor = bytes.index(after: cursor)
            }
            try append(bytes[start...]); try append([34])
            return String(decoding: output, as: UTF8.self)
        }

        mutating func write(_ value: Any, depth: Int, prefix: String, suffix: String,
                            append: (String) -> Bool, cancelled: () -> Bool) throws -> Bool {
            guard !cancelled() else { throw CancellationError() }
            let indent = String(repeating: "  ", count: depth)
            if let dictionary = value as? [String: Any] {
                let keys = dictionary.keys.sorted()
                if keys.isEmpty { return try emit(prefix + "{}" + suffix, append: append, cancelled: cancelled) }
                guard try emit(prefix + "{", append: append, cancelled: cancelled) else { return false }
                for (index, key) in keys.enumerated() {
                    let head = try indent + "  " + quoted(key, cancelled: cancelled) + ": "
                    guard try write(dictionary[key]!, depth: depth + 1, prefix: head,
                                    suffix: index + 1 == keys.count ? "" : ",", append: append,
                                    cancelled: cancelled) else { return false }
                }
                return try emit(indent + "}" + suffix, append: append, cancelled: cancelled)
            }
            if let array = value as? [Any] {
                if array.isEmpty { return try emit(prefix + "[]" + suffix, append: append, cancelled: cancelled) }
                guard try emit(prefix + "[", append: append, cancelled: cancelled) else { return false }
                for (index, item) in array.enumerated() {
                    guard try write(item, depth: depth + 1, prefix: indent + "  ",
                                    suffix: index + 1 == array.count ? "" : ",", append: append,
                                    cancelled: cancelled) else { return false }
                }
                return try emit(indent + "]" + suffix, append: append, cancelled: cancelled)
            }
            let encoded: String
            if let text = value as? String { encoded = try quoted(text, cancelled: cancelled) }
            else if value is NSNull { encoded = "null" }
            else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { encoded = number.boolValue ? "true" : "false" }
                else { encoded = String(decoding: try JSONSerialization.data(withJSONObject: number, options: [.fragmentsAllowed]), as: UTF8.self) }
            } else { throw Failure.unsupportedValue }
            return try emit(prefix + encoded + suffix, append: append, cancelled: cancelled)
        }
    }
}
