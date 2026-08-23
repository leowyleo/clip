import Foundation
import ClipCore

/// Returns as soon as work finishes, the deadline expires, or the caller is
/// cancelled. The work is unstructured on purpose: a synchronous image encoder
/// must never keep the user-facing task stuck while a cancelled worker unwinds.
func withProcessingDeadline<Value: Sendable>(
    nanoseconds: UInt64 = 8_000_000_000,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = ProcessingRace<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)

            let work = Task.detached(priority: .userInitiated) {
                do {
                    race.resolve(.success(try await operation()))
                } catch {
                    race.resolve(.failure(error))
                }
            }
            race.registerWork(work)

            let timer = Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                    try Task.checkCancellation()
                    race.resolve(.failure(ClipError.processingTimedOut))
                } catch {
                    // The winning operation cancels this timer.
                }
            }
            race.registerTimer(timer)
        }
    } onCancel: {
        race.resolve(.failure(CancellationError()))
    }
}

private final class ProcessingRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func registerWork(_ task: Task<Void, Never>) {
        register(task, asTimer: false)
    }

    func registerTimer(_ task: Task<Void, Never>) {
        register(task, asTimer: true)
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let work = self.work
        let timer = self.timer
        self.work = nil
        self.timer = nil
        lock.unlock()

        work?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }

    private func register(_ task: Task<Void, Never>, asTimer: Bool) {
        lock.lock()
        if isResolved {
            lock.unlock()
            task.cancel()
            return
        }
        if asTimer {
            timer = task
        } else {
            work = task
        }
        lock.unlock()
    }
}
