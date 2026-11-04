import Foundation

/// Raised for items that never started because the caller cancelled the batch.
public enum ParallelBatchError: LocalizedError, Equatable {
    case cancelled

    public var errorDescription: String? {
        "并行批处理已取消，该项目尚未开始处理。"
    }
}

/// Result of one `ParallelBatch.run` call.
///
/// `results` always has exactly one entry per input item and stays in input
/// order, so callers can zip it with the input even when work completed out of
/// order. Per-item errors are isolated here; they never abort the batch.
public struct ParallelBatchOutcome<Value> {
    /// One entry per input item, in the original input order.
    public let results: [Result<Value, Error>]
    /// True when the batch stopped early because the caller's task or
    /// `CancellationToken` was cancelled. Items that never started are recorded
    /// as `.failure(ParallelBatchError.cancelled)` so callers can report
    /// skipped work without treating it as an image failure.
    public let cancelled: Bool
    /// Concurrency actually used after clamping the request to 1...8.
    public let effectiveConcurrency: Int

    public init(results: [Result<Value, Error>], cancelled: Bool, effectiveConcurrency: Int) {
        self.results = results
        self.cancelled = cancelled
        self.effectiveConcurrency = effectiveConcurrency
    }

    /// Successful values in input order (failed/skipped entries removed).
    public var values: [Value] {
        results.compactMap { try? $0.get() }
    }

    public var succeededCount: Int { values.count }
    public var failedCount: Int { results.count - succeededCount }

    /// Indexes of every non-successful entry, with the recorded error.
    public var failures: [(index: Int, error: Error)] {
        results.enumerated().compactMap { index, result in
            switch result {
            case .success: return nil
            case .failure(let error): return (index, error)
            }
        }
    }

    /// Indexes that were skipped because the batch was cancelled before they
    /// started (as opposed to items that started and then failed).
    public var skippedByCancellation: [Int] {
        results.enumerated().compactMap { index, result in
            guard case .failure(let error) = result,
                  let batchError = error as? ParallelBatchError,
                  batchError == .cancelled else { return nil }
            return index
        }
    }
}

/// Bounded-concurrency executor for ordered batch work.
///
/// The executor keeps at most `maxConcurrency` operations running at once, keeps
/// results in input order, isolates per-item failures and supports both
/// cooperative task cancellation and an external `CancellationToken` (the token
/// used by `BatchProcessor` so a UI cancel button can stop a running export).
///
/// The API is intentionally `async` and uses structured concurrency only — there
/// are no semaphores, locks or blocking waits on the calling thread, so awaiting
/// it from a background queue never blocks the main thread.
public enum ParallelBatch {
    /// Supported concurrency range. Requests outside it are clamped rather than
    /// trapping, so a bad UI value cannot crash an export.
    public static let allowedConcurrency = 1...8
    /// Default used by the app's batch export and by the benchmark.
    public static let defaultConcurrency = 4

    /// Clamps a requested concurrency into `allowedConcurrency`.
    public static func effectiveConcurrency(_ requested: Int) -> Int {
        min(allowedConcurrency.upperBound, max(allowedConcurrency.lowerBound, requested))
    }

    /// Runs `operation` for every item with bounded concurrency.
    ///
    /// - Parameters:
    ///   - items: Inputs; the outcome keeps this order regardless of completion order.
    ///   - maxConcurrency: Requested concurrency, clamped to 1...8.
    ///   - cancellation: Optional external token (checked before scheduling each
    ///     item and after each completion). A cancelled batch returns promptly
    ///     with `cancelled == true`.
    ///   - progress: Called with the number of finished items (1...count,
    ///     monotonically increasing) as work completes. It is called from the
    ///     batch executor, not necessarily the main thread; wrap UI updates in
    ///     `await MainActor.run` / `DispatchQueue.main`.
    ///   - operation: Per-item work. A thrown error is recorded for that item
    ///     only; remaining items keep running (failure isolation).
    /// - Returns: Ordered per-item results plus cancellation/concurrency metadata.
    public static func run<Item, Value>(
        items: [Item],
        maxConcurrency: Int = defaultConcurrency,
        cancellation: CancellationToken? = nil,
        progress: ((Int) -> Void)? = nil,
        operation: @escaping (Item) async throws -> Value
    ) async -> ParallelBatchOutcome<Value> {
        let concurrency = effectiveConcurrency(maxConcurrency)
        guard !items.isEmpty else {
            return ParallelBatchOutcome(results: [], cancelled: false, effectiveConcurrency: concurrency)
        }
        if isCancelled(cancellation) {
            return ParallelBatchOutcome(
                results: items.map { _ in .failure(ParallelBatchError.cancelled) },
                cancelled: true,
                effectiveConcurrency: concurrency)
        }

        var results = [Result<Value, Error>?](repeating: nil, count: items.count)
        var nextIndex = 0
        var finished = 0
        var cancelled = false

        await withTaskGroup(of: (Int, Result<Value, Error>).self) { group in
            // Fill the initial window.
            let initialWindow = min(concurrency, items.count)
            while nextIndex < initialWindow {
                let index = nextIndex
                let item = items[index]
                group.addTask {
                    do {
                        return (index, .success(try await operation(item)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
                nextIndex += 1
            }

            while let (index, result) = await group.next() {
                results[index] = result
                finished += 1
                progress?(finished)

                if isCancelled(cancellation) {
                    if !cancelled {
                        cancelled = true
                        group.cancelAll()
                    }
                    continue
                }
                if nextIndex < items.count {
                    let index = nextIndex
                    let item = items[index]
                    group.addTask {
                        do {
                            return (index, .success(try await operation(item)))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                    nextIndex += 1
                }
            }
        }

        let ordered = results.enumerated().map { index, result -> Result<Value, Error> in
            result ?? .failure(ParallelBatchError.cancelled)
        }
        return ParallelBatchOutcome(results: ordered, cancelled: cancelled, effectiveConcurrency: concurrency)
    }

    private static func isCancelled(_ cancellation: CancellationToken?) -> Bool {
        if cancellation?.isCancelled == true { return true }
        return Task.isCancelled
    }
}

/// Small monotonic timing helpers for tests, benchmark and integration code.
public enum Measure {
    /// Monotonic uptime in nanoseconds (immune to wall-clock changes).
    public static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Milliseconds between two `now()` samples.
    public static func elapsed(since start: UInt64, until end: UInt64 = Measure.now()) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }

    /// Times synchronous work and returns both the value and elapsed milliseconds.
    public static func elapsed<T>(_ body: () throws -> T) rethrows -> (value: T, milliseconds: Double) {
        let start = now()
        let value = try body()
        return (value, elapsed(since: start))
    }

    /// Times asynchronous work and returns both the value and elapsed milliseconds.
    public static func elapsed<T>(_ body: () async throws -> T) async rethrows -> (value: T, milliseconds: Double) {
        let start = now()
        let value = try await body()
        return (value, elapsed(since: start))
    }
}
