//
//  AsyncStreamHub.swift
//
//  Copyright (c) 2026 Daniel Murfin
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// Async Stream Hub
///
/// A broadcast fan-out over `AsyncStream`. `AsyncStream` is single-consumer, but the component event
/// streams (`data`, `events`) are exposed as properties that may be observed by more than one consumer;
/// this hub delivers each element to every active subscriber. Subscribers are removed automatically when
/// their stream terminates (consumer cancellation or the hub finishing).
///
/// Access is guarded by a lock so the `onTermination` callback (which fires from an arbitrary context)
/// is safe alongside in-isolation `yield`; the type is `@unchecked Sendable`. It uses no SwiftNIO types
/// so it stays above the transport layer.
///
final class AsyncStreamHub<Element: Sendable>: @unchecked Sendable {

    /// The lock guarding the mutable state.
    private let lock = NSLock()

    /// The buffering policy applied to every stream from this hub (fixed per hub kind so a subscribe site
    /// cannot accidentally default to unbounded).
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    /// The active subscriber continuations, keyed by a per-subscription identifier.
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    /// A cached array of the active continuations, rebuilt only on subscribe/terminate/finish so `yield`
    /// (the wire-rate hot path) allocates nothing.
    private var active: [AsyncStream<Element>.Continuation] = []

    /// Whether the hub has finished; further streams are handed back already-finished.
    private var isFinished = false

    /// Creates a hub with a fixed buffering policy.
    ///
    /// - Parameters:
    ///    - bufferingPolicy: The buffering policy applied to every stream. Use `.bufferingNewest(1)` for
    ///      high-rate data (a slow consumer gets the latest frame) and a bounded policy for events.
    ///
    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy) {
        self.bufferingPolicy = bufferingPolicy
    }

    /// Returns a fresh stream subscribed to this hub.
    ///
    /// If the hub has already finished, the returned stream is already finished (it never suspends
    /// forever), so a consumer that subscribes after teardown terminates immediately.
    ///
    /// - Returns: An `AsyncStream` that yields every element passed to `yield(_:)` while it is active.
    ///
    func stream() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            let finished: Bool = lock.withLock {
                guard !isFinished else { return true }
                continuations[id] = continuation
                active = Array(continuations.values)
                return false
            }
            if finished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    self.continuations.removeValue(forKey: id)
                    self.active = Array(self.continuations.values)
                }
            }
        }
    }

    /// Yields an element to every active subscriber.
    ///
    /// - Parameters:
    ///    - element: The element to broadcast.
    ///
    func yield(_ element: Element) {
        // Snapshot under the lock, then yield outside it: `yield`/`finish` can synchronously fire a
        // consumer's `onTermination`, which re-acquires this lock - holding it here would deadlock.
        let subscribers = lock.withLock { active }
        for continuation in subscribers {
            continuation.yield(element)
        }
    }

    /// Finishes every subscriber's stream and marks the hub finished.
    func finish() {
        let subscribers = lock.withLock { () -> [AsyncStream<Element>.Continuation] in
            isFinished = true
            let values = active
            continuations.removeAll()
            active = []
            return values
        }
        for continuation in subscribers {
            continuation.finish()
        }
    }

}
