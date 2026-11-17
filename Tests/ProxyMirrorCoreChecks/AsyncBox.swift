import Foundation

/// 单线程测试里等待异步脚本结果的轻量信箱
final class NSBox<T: Sendable> {
    private let lock = NSLock()
    private var value: T?
    private var done = false

    func store(_ newValue: T) {
        lock.lock(); self.value = newValue; done = true; lock.unlock()
    }

    func wait(timeout: TimeInterval = 8) -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        lock.lock(); defer { lock.unlock() }
        return value!
    }
}
