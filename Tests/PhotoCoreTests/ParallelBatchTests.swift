import XCTest
@testable import PhotoCore

/// Thread-safe probe used to observe how many operations run at the same time.
private final class ConcurrencyProbe {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var starts = 0

    func begin() {
        lock.lock()
        active += 1
        starts += 1
        peak = max(peak, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    var maxActive: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return starts
    }
}

private enum TestFailure: Error, Equatable {
    case synthetic(Int)
}

final class ParallelBatchTests: XCTestCase {
    // MARK: - Configuration and empty input

    func testEffectiveConcurrencyClampsToSupportedRange() {
        XCTAssertEqual(ParallelBatch.effectiveConcurrency(-3), 1)
        XCTAssertEqual(ParallelBatch.effectiveConcurrency(0), 1)
        XCTAssertEqual(ParallelBatch.effectiveConcurrency(1), 1)
        XCTAssertEqual(ParallelBatch.effectiveConcurrency(4), 4)
        XCTAssertEqual(ParallelBatch.effectiveConcurrency(8), 8)
        XCTAssertEqual(ParallelBatch.effectiveConcurrency(9), 8)
        XCTAssertEqual(ParallelBatch.effectiveConcurrency(1_000), 8)
        XCTAssertEqual(ParallelBatch.allowedConcurrency, 1...8)
        XCTAssertEqual(ParallelBatch.defaultConcurrency, 4)
    }

    func testEmptyInputReturnsEmptyOutcomeWithoutProgress() async {
        var progressCalls = 0
        let outcome = await ParallelBatch.run(items: [Int](), maxConcurrency: 4,
                                              progress: { _ in progressCalls += 1 }) { item in
            item * 2
        }
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(outcome.effectiveConcurrency, 4)
        XCTAssertEqual(progressCalls, 0)
    }

    // MARK: - Ordering and determinism

    func testResultsKeepInputOrderForEveryConcurrency() async {
        let items = Array(0..<40)
        for requested in [1, 2, 4, 8, 99] {
            let outcome = await ParallelBatch.run(items: items, maxConcurrency: requested) { item in
                // Different completion delays scramble completion order on purpose.
                try await Task.sleep(nanoseconds: UInt64((items.count - item) % 7) * 1_000_000)
                return item * 3
            }
            XCTAssertFalse(outcome.cancelled)
            XCTAssertEqual(outcome.results.count, items.count)
            XCTAssertEqual(outcome.values, items.map { $0 * 3 })
            XCTAssertEqual(outcome.failedCount, 0)
            XCTAssertEqual(outcome.effectiveConcurrency, ParallelBatch.effectiveConcurrency(requested))
            XCTAssertEqual(outcome.results.map { try? $0.get() }, items.map { Optional($0 * 3) })
        }
    }

    // MARK: - Bounded concurrency

    func testConcurrencyNeverExceedsLimitAndSerialRunsOneAtATime() async {
        let items = Array(0..<24)

        let parallelProbe = ConcurrencyProbe()
        let parallelOutcome = await ParallelBatch.run(items: items, maxConcurrency: 4) { item in
            parallelProbe.begin()
            defer { parallelProbe.end() }
            try await Task.sleep(nanoseconds: 25_000_000)
            return item
        }
        XCTAssertFalse(parallelOutcome.cancelled)
        XCTAssertEqual(parallelOutcome.succeededCount, items.count)
        XCTAssertLessThanOrEqual(parallelProbe.maxActive, 4, "running operations must stay within the bound")
        XCTAssertGreaterThanOrEqual(parallelProbe.maxActive, 3, "a bounded window should actually reach the limit")
        XCTAssertEqual(parallelProbe.startCount, items.count)

        let serialProbe = ConcurrencyProbe()
        let serialOutcome = await ParallelBatch.run(items: items, maxConcurrency: 1) { item in
            serialProbe.begin()
            defer { serialProbe.end() }
            try await Task.sleep(nanoseconds: 2_000_000)
            return item
        }
        XCTAssertEqual(serialOutcome.values, items)
        XCTAssertEqual(serialProbe.maxActive, 1)

        let clampedOutcome = await ParallelBatch.run(items: items, maxConcurrency: 0) { item in item }
        XCTAssertEqual(clampedOutcome.effectiveConcurrency, 1)
        let highOutcome = await ParallelBatch.run(items: items, maxConcurrency: 64) { item in item }
        XCTAssertEqual(highOutcome.effectiveConcurrency, 8)
    }

    // MARK: - Failure isolation

    func testPerItemFailuresAreIsolatedAndDoNotAbortTheBatch() async {
        let items = Array(0..<16)
        let outcome = await ParallelBatch.run(items: items, maxConcurrency: 4) { item in
            if item.isMultiple(of: 2) { throw TestFailure.synthetic(item) }
            return item * 10
        }
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(outcome.results.count, items.count)
        XCTAssertEqual(outcome.failedCount, 8)
        XCTAssertEqual(outcome.succeededCount, 8)
        XCTAssertEqual(outcome.values, items.filter { !$0.isMultiple(of: 2) }.map { $0 * 10 })
        XCTAssertEqual(outcome.failures.map { $0.index }, items.filter { $0.isMultiple(of: 2) })
        for (index, error) in outcome.failures {
            XCTAssertEqual(error as? TestFailure, .synthetic(index))
        }
        XCTAssertTrue(outcome.skippedByCancellation.isEmpty)
    }

    // MARK: - Cancellation

    func testExternalTokenCancellationStopsSchedulingAndMarksSkippedItems() async {
        let items = Array(0..<40)
        let token = CancellationToken()
        var progressCounts: [Int] = []
        let lock = NSLock()
        let start = Measure.now()

        let outcome = await ParallelBatch.run(items: items, maxConcurrency: 4,
                                              cancellation: token,
                                              progress: { finished in
            lock.lock()
            progressCounts.append(finished)
            if finished >= 4 { token.cancel() }
            lock.unlock()
        }, operation: { item in
            try await Task.sleep(nanoseconds: 20_000_000)
            return item
        })
        let elapsedMilliseconds = Measure.elapsed(since: start)

        XCTAssertTrue(outcome.cancelled, "cancelling the token must be reported")
        XCTAssertEqual(outcome.results.count, items.count)
        XCTAssertLessThan(outcome.succeededCount, items.count)
        XCTAssertGreaterThanOrEqual(outcome.succeededCount, 4, "items finished before the cancel are kept")
        XCTAssertFalse(outcome.skippedByCancellation.isEmpty,
                       "items that never started must be marked as cancelled skips")
        XCTAssertEqual(outcome.succeededCount + outcome.failedCount, items.count)
        XCTAssertEqual(progressCounts, Array(progressCounts.sorted()),
                       "progress must be monotonically increasing")
        // Cancelling after the first few items must return well before the serial
        // duration (40 * 20 ms = 800 ms) rather than draining the whole queue.
        XCTAssertLessThan(elapsedMilliseconds, Double(items.count) * 20 * 0.5,
                          "a cancelled batch must return promptly")
    }

    func testCancellationBeforeStartSkipsEverything() async {
        let token = CancellationToken()
        token.cancel()
        let outcome = await ParallelBatch.run(items: Array(0..<5), maxConcurrency: 4,
                                              cancellation: token) { item in
            XCTFail("operation must not run for a pre-cancelled batch")
            return item
        }
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.results.count, 5)
        XCTAssertEqual(outcome.skippedByCancellation, Array(0..<5))
        XCTAssertEqual(outcome.succeededCount, 0)
    }

    // MARK: - Progress

    func testProgressIsMonotonicAndReportsEveryFinishedItem() async {
        let items = Array(0..<12)
        let lock = NSLock()
        var counts: [Int] = []
        let outcome = await ParallelBatch.run(items: items, maxConcurrency: 3,
                                              progress: { finished in
            lock.lock(); counts.append(finished); lock.unlock()
        }) { item in
            try await Task.sleep(nanoseconds: UInt64(item % 3) * 1_000_000)
            return item
        }
        XCTAssertEqual(outcome.succeededCount, items.count)
        XCTAssertEqual(counts, Array(1...items.count))
    }

    // MARK: - Serial vs parallel speedup

    func testParallelIsFasterThanSerialForSleepBoundWork() async throws {
        let items = Array(0..<16)
        let delay: UInt64 = 30_000_000

        let serial = try await Measure.elapsed {
            await ParallelBatch.run(items: items, maxConcurrency: 1) { item in
                try await Task.sleep(nanoseconds: delay)
                return item
            }
        }
        XCTAssertEqual(serial.value.succeededCount, items.count)

        let parallel = try await Measure.elapsed {
            await ParallelBatch.run(items: items, maxConcurrency: 4) { item in
                try await Task.sleep(nanoseconds: delay)
                return item
            }
        }
        XCTAssertEqual(parallel.value.succeededCount, items.count)
        XCTAssertEqual(parallel.value.values, items)

        let speedup = serial.milliseconds / max(parallel.milliseconds, 0.001)
        print(String(format: "ParallelBatch speedup probe: serial=%.1fms parallel(4)=%.1fms speedup=%.2fx",
                     serial.milliseconds, parallel.milliseconds, speedup))
        XCTAssertLessThan(parallel.milliseconds, serial.milliseconds * 0.8,
                          "bounded parallel work should be materially faster than serial work")
        XCTAssertGreaterThan(speedup, 1.25)
    }

    // MARK: - Measure helper

    func testMeasureElapsedTimesSynchronousAndAsynchronousWork() async throws {
        let sync = try Measure.elapsed { () -> Int in
            var total = 0
            for value in 0..<10_000 { total += value }
            return total
        }
        XCTAssertEqual(sync.value, 49_995_000)
        XCTAssertGreaterThanOrEqual(sync.milliseconds, 0)

        let async = try await Measure.elapsed {
            try await Task.sleep(nanoseconds: 20_000_000)
            return "done"
        }
        XCTAssertEqual(async.value, "done")
        XCTAssertGreaterThanOrEqual(async.milliseconds, 10)
        XCTAssertLessThan(async.milliseconds, 2_000)

        let start = Measure.now()
        XCTAssertGreaterThanOrEqual(Measure.elapsed(since: start), 0)
    }
}
