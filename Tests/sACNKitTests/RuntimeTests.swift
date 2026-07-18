import Foundation
import NIOPosix
import Testing

@testable import sACNKit

/// Unit tests for the Phase 4 runtime primitives (PR1): the broadcast stream hub and the `NIORuntime`
/// executor + scheduler. No components are converted yet.
@Suite("Phase 4 runtime primitives")
struct RuntimeTests {

    // MARK: AsyncStreamHub

    @Test("The hub broadcasts every element to all active subscribers")
    func hubBroadcasts() async {
        let hub = AsyncStreamHub<Int>(bufferingPolicy: .unbounded)
        let first = hub.stream()
        let second = hub.stream()

        hub.yield(1)
        hub.yield(2)
        hub.finish()

        var firstValues: [Int] = []
        for await value in first { firstValues.append(value) }
        var secondValues: [Int] = []
        for await value in second { secondValues.append(value) }

        #expect(firstValues == [1, 2])
        #expect(secondValues == [1, 2])
    }

    @Test("A buffering-newest(1) stream keeps only the latest un-consumed element")
    func hubBufferingNewest() async {
        let hub = AsyncStreamHub<Int>(bufferingPolicy: .bufferingNewest(1))
        let stream = hub.stream()

        hub.yield(1)
        hub.yield(2)
        hub.yield(3)
        hub.finish()

        var values: [Int] = []
        for await value in stream { values.append(value) }
        #expect(values == [3])
    }

    @Test("A stream subscribed after finish() terminates immediately")
    func hubFinishedIsTerminal() async {
        let hub = AsyncStreamHub<Int>(bufferingPolicy: .unbounded)
        hub.finish()

        let late = hub.stream()
        var values: [Int] = []
        for await value in late { values.append(value) }
        #expect(values.isEmpty)
    }

    // MARK: Executor

    /// A minimal actor isolated to a runtime's serial executor, used to prove the isolation runs on the
    /// NIO event loop.
    private actor OnLoopActor {

        nonisolated let runtime: NIORuntime
        nonisolated var unownedExecutor: UnownedSerialExecutor { runtime.serialExecutor.asUnownedSerialExecutor() }

        init(_ runtime: NIORuntime) { self.runtime = runtime }

        func runsOnEventLoop() -> Bool { runtime.eventLoop.inEventLoop }

    }

    @Test("An actor pinned to the runtime executor runs its isolation on the NIO event loop")
    func actorRunsOnEventLoop() async {
        let runtime = NIORuntime()
        let actor = OnLoopActor(runtime)
        #expect(await actor.runsOnEventLoop() == true)
    }

    // MARK: Scheduling

    @Test("scheduleOnce fires its body while the handle is retained")
    func scheduleOnceFires() async {
        let runtime = NIORuntime()
        let handle = LockedBox<any RuntimeTask>()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            handle.value = runtime.scheduleOnce(after: .milliseconds(10)) { continuation.resume() }
        }
        #expect(handle.value != nil)
    }

    @Test("Dropping a repeated task handle without cancel() stops it")
    func droppedRepeatedStops() async throws {
        let runtime = NIORuntime()
        let counter = Counter()
        do {
            let task = runtime.scheduleRepeated(after: .milliseconds(5), every: .milliseconds(5)) { counter.increment() }
            try await Task.sleep(for: .milliseconds(40))
            #expect(counter.value > 0, "fired while the handle was held")
            withExtendedLifetime(task) {}
        }

        // Handle dropped -> deinit -> cancel; the count must settle.
        try await Task.sleep(for: .milliseconds(30))
        let settled = counter.value
        try await Task.sleep(for: .milliseconds(40))
        #expect(counter.value == settled, "stopped after the handle was dropped")
    }

    @Test("cancel() stops a repeating task")
    func cancelStopsRepeated() async throws {
        let runtime = NIORuntime()
        let counter = Counter()
        let task = runtime.scheduleRepeated(after: .milliseconds(5), every: .milliseconds(5)) { counter.increment() }

        try await Task.sleep(for: .milliseconds(60))
        #expect(counter.value > 0, "the task fired before cancel")
        task.cancel()

        // Allow any occurrence already dequeued at cancel time to run, then assert the count is stable
        // across a further gap (robust to off-loop cancel latency).
        try await Task.sleep(for: .milliseconds(40))
        let settled = counter.value
        try await Task.sleep(for: .milliseconds(40))
        #expect(counter.value == settled, "no occurrences after cancel settles")
    }

    @Test("A stalled loop coalesces missed occurrences instead of replaying them")
    func stalledRepeatedCoalesces() async throws {
        // A dedicated single-thread group so stalling the loop does not disturb suites sharing the
        // singleton group's loops. Its thread is awaited to completion at teardown (below) - a
        // fire-and-forget `shutdownGracefully { _ in }` could leave the stalled thread outliving the test.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let runtime = NIORuntime(eventLoop: group.next())
            let counter = Counter()

            let task = runtime.scheduleRepeated(after: .milliseconds(50), every: .milliseconds(50)) { counter.increment() }
            try await Task.sleep(for: .milliseconds(75))
            let beforeStall = counter.value

            // Stall the loop across ~10 would-be occurrences, then observe shortly after it resumes.
            runtime.eventLoop.execute { Thread.sleep(forTimeInterval: 0.5) }
            try await Task.sleep(for: .milliseconds(560))
            let burst = counter.value - beforeStall
            task.cancel()

            // Coalescing yields the single advanced-deadline fire plus a few on-schedule fires in the
            // observation margin (~3); replaying every missed occurrence would yield 10 or more.
            #expect(burst <= 5, "missed occurrences must be coalesced, not replayed (burst=\(burst))")
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

}

/// A thread-safe integer counter for the scheduling tests. (`LockedBox` holds an optional value and
/// cannot increment atomically, so this small counter is not a duplicate of it.)
private final class Counter: @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }

}
