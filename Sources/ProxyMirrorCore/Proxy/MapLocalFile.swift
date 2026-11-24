import Darwin
import Foundation
import NIOCore
import NIOPosix

enum MapLocalFileWorker {
    static let preparationSlots = DispatchSemaphore(value: 8)
    static let pool: NIOThreadPool = {
        let pool = NIOThreadPool(numberOfThreads: 2)
        pool.start()
        return pool
    }()
    static let fileIO = NonBlockingFileIO(threadPool: pool)

    struct Busy: LocalizedError, OperationIssueProviding {
        var operationIssue: OperationIssue { .networkLocalFileBusy }
        var errorDescription: String? { operationIssue.diagnostic }
    }
}

final class MapLocalFile: Sendable {
    static let chunkSize = 128 * 1024
    // Each response can retain one pending chunk. This bounds pending file data
    // across all H1 connections and H2 streams to 8 MiB.
    private static let streamingSlots = DispatchSemaphore(value: 64)
    private let handle: NIOFileHandle
    let length: Int

    private init(descriptor: CInt, length: Int) {
        handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: descriptor)
        self.length = length
    }

    deinit {
        try? handle.close()
        Self.streamingSlots.signal()
    }

    /// Called on the file worker. Get the length from the same descriptor used for reads.
    static func open(_ url: URL, includeBody: Bool) throws -> (length: Int, body: MapLocalFile?)? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var keepDescriptor = false
        defer { if !keepDescriptor { Darwin.close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let length = Int(exactly: info.st_size), length >= 0 else { return nil }
        guard includeBody, length > 0 else { return (length, nil) }
        guard streamingSlots.wait(timeout: .now()) == .success else { throw MapLocalFileWorker.Busy() }
        keepDescriptor = true
        return (length, MapLocalFile(descriptor: descriptor, length: length))
    }

    func read(offset: Int, length: Int, on channel: Channel) -> EventLoopFuture<ByteBuffer> {
        MapLocalFileWorker.fileIO.read(fileHandle: handle, fromOffset: Int64(offset), byteCount: length,
                                       allocator: channel.allocator, eventLoop: channel.eventLoop)
    }
}

/// A channel's event loop owns the sender. The next file read waits for the current
/// write to complete, including flow control on HTTP/2, and for channel writability.
final class MapLocalSender {
    private struct UnexpectedEndOfFile: LocalizedError, OperationIssueProviding {
        var operationIssue: OperationIssue { .networkLocalFileTruncated }
        var errorDescription: String? { operationIssue.diagnostic }
    }

    private let file: MapLocalFile
    private weak var channel: Channel?
    private let write: (Channel, ByteBuffer) -> EventLoopFuture<Void>
    private var completion: ((Result<Void, Error>) -> Void)?
    private var offset = 0
    private var inProgress = false

    init(file: MapLocalFile, channel: Channel, write: @escaping (Channel, ByteBuffer) -> EventLoopFuture<Void>,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.file = file
        self.channel = channel
        self.write = write
        self.completion = completion
    }

    func resume() {
        guard let channel, channel.isActive, channel.isWritable, !inProgress, completion != nil else { return }
        let length = min(file.length - offset, MapLocalFile.chunkSize)
        inProgress = true
        file.read(offset: offset, length: length, on: channel).flatMap { [self] buffer -> EventLoopFuture<Void> in
            guard completion != nil, channel.isActive else {
                return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
            }
            guard buffer.readableBytes == length else {
                return channel.eventLoop.makeFailedFuture(UnexpectedEndOfFile())
            }
            return write(channel, buffer)
        }.whenComplete { [self] result in
            inProgress = false
            if case .success = result {
                offset += length
                if offset < file.length {
                    resume()
                    return
                }
            }
            let done = completion
            completion = nil
            done?(result)
        }
    }

    func cancel() { completion = nil }
}
