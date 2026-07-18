import Foundation

@testable import sACNKit

/// A tiny thread-safe box for values written from delegate callbacks.
///
/// Hoisted here so socket-facing suites share one implementation rather than each
/// carrying a private copy.
final class LockedBox<T> {

    private let lock = NSLock()
    private var _value: T?

    init(_ value: T? = nil) {
        _value = value
    }

    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

}

/// Drains an `AsyncStream` into a thread-safe, growing buffer for assertions.
///
/// The component actors deliver via `AsyncStream`s rather than delegate callbacks, so the socket-facing
/// suites subscribe once at construction (before injecting packets) and poll the accumulated elements.
///
/// What a collector can observe depends on the hub's buffering. The raw per-source `data` stream and every
/// `events`/`debugLog` stream buffer `.bufferingNewest(64)`, so a burst smaller than 64 is captured
/// losslessly and in order even if this collector's drain `Task` lags the producer. The **merged and group
/// `data`** streams buffer `.bufferingNewest(1)` (each frame is a complete DMX snapshot), so a collector on
/// those reliably observes only the *latest* frame under lag - assert on latest state (e.g. `waitFor`/`all.last`)
/// or on `count >= 1`, not on every intermediate frame.
final class StreamCollector<Element: Sendable> {

    private let lock = NSLock()
    private var items: [Element] = []
    private var drain: Task<Void, Never>!

    /// Subscribes to `stream` and begins draining it into the buffer.
    init(_ stream: AsyncStream<Element>) {
        drain = Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                self.lock.withLock { self.items.append(element) }
            }
        }
    }

    deinit {
        drain.cancel()
    }

    /// Every element received so far, in arrival order.
    var all: [Element] { lock.withLock { items } }

    /// The number of elements received so far.
    var count: Int { lock.withLock { items.count } }

    /// Waits until at least `n` elements have arrived (or the timeout elapses).
    ///
    /// - Returns: `true` if `n` elements arrived in time.
    ///
    func waitForCount(_ n: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if count >= n { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return count >= n
    }

    /// Waits until at least `n` elements satisfying `predicate` have arrived (or the timeout elapses).
    func waitForCount(_ n: Int, timeout: Duration = .seconds(5), where predicate: @Sendable (Element) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if all.lazy.filter(predicate).count >= n { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return all.lazy.filter(predicate).count >= n
    }

    /// Waits until an element satisfying `predicate` has arrived (or the timeout elapses).
    func waitFor(timeout: Duration = .seconds(5), where predicate: @Sendable (Element) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if all.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return all.contains(where: predicate)
    }

    /// Asserts no further elements arrive: after a quiet period the count still equals `expected`.
    ///
    /// - Returns: `true` if exactly `expected` elements are held after the quiet window.
    ///
    func expectNoMore(count expected: Int, quiet: Duration = .milliseconds(150)) async -> Bool {
        try? await Task.sleep(for: quiet)
        return count == expected
    }

    /// Asserts no further elements satisfying `predicate` arrive: after a quiet period exactly `expected`
    /// matching elements are held.
    func expectNoMore(count expected: Int, quiet: Duration = .milliseconds(150), where predicate: @Sendable (Element) -> Bool) async -> Bool {
        try? await Task.sleep(for: quiet)
        return all.lazy.filter(predicate).count == expected
    }

}

/// A recording `ComponentSocketDelegate` for exercising socket implementations directly.
final class RecordingSocketDelegate: ComponentSocketDelegate {

    /// A received datagram, captured for assertions.
    struct Received {

        let data: Data
        let host: String
        let port: UInt16
        let family: ComponentSocketIPFamily

    }

    private let lock = NSLock()
    private var _received: [Received] = []
    private var _closeReason: SocketCloseReason?

    /// Signalled on each received datagram.
    let receivedSemaphore = DispatchSemaphore(value: 0)

    /// All datagrams received so far.
    var received: [Received] { lock.withLock { _received } }

    /// The reason reported by the last socket close, if any.
    var closeReason: SocketCloseReason? { lock.withLock { _closeReason } }

    func receivedMessage(
        for socket: ComponentSocket, withData data: Data, sourceHostname: String, sourcePort: UInt16, ipFamily: ComponentSocketIPFamily
    ) {
        lock.withLock { _received.append(Received(data: data, host: sourceHostname, port: sourcePort, family: ipFamily)) }
        receivedSemaphore.signal()
    }

    func socket(_ socket: ComponentSocket, socketDidCloseWith reason: SocketCloseReason) {
        lock.withLock { _closeReason = reason }
    }

    func debugLog(for socket: ComponentSocket, with logMessage: String) {}

}
