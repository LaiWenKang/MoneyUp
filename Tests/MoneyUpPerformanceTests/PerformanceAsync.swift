import Foundation

final class PerformanceAsyncResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ newResult: Result<Value, Error>) {
        lock.lock()
        result = newResult
        lock.unlock()
    }

    func take() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// XCTest's performance block is synchronous. This bridge keeps actor work on
/// a detached task while the test runner waits for exactly that operation.
func waitForPerformanceOperation<Value: Sendable>(
    _ operation: @Sendable @escaping () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = PerformanceAsyncResult<Value>()
    Task.detached {
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.take() else {
        preconditionFailure("Detached performance operation returned no result")
    }
    return try result.get()
}
