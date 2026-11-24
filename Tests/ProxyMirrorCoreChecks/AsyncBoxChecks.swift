import Foundation

func checkAsyncMailbox(_ test: CoreAssertions) throws {
    let mailbox = NSBox<Int>()
    DispatchQueue.global().async { mailbox.store(42) }
    test.equal(try mailbox.wait(timeout: 2), 42, "Async mailbox delivers a worker-thread result")
    let optional = NSBox<Int?>()
    optional.store(nil)
    test.equal(try optional.wait(timeout: 0.02), nil, "Async mailbox distinguishes a nil result from no completion")
    test.rejects(try NSBox<Int>().wait(timeout: 0.02), with: NSBox<Int>.Timeout.self,
                 "Missing asynchronous completion fails within the requested deadline")
}
