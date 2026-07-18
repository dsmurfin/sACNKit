//
//  NIORuntime.swift
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
import NIOCore
import NIOPosix

/// NIO One-Shot Task
///
/// A `RuntimeTask` wrapping a single NIO `Scheduled` task. The scheduled closure holds `self` **weakly**,
/// so dropping the handle deinits it and cancels the fire (drop == cancel, matching `NIORepeatedTask`);
/// the handle must be retained until the task should fire. An explicit `cancel()` is checked at fire time
/// too. An occurrence already dequeued at cancel/drop time may still complete once.
///
final class NIOOneShotTask: RuntimeTask, @unchecked Sendable {

    /// The lock guarding `cancelled` and `scheduled`.
    private let lock = NSLock()

    /// Whether the task has been cancelled.
    private var cancelled = false

    /// The scheduled occurrence, if still armed.
    private var scheduled: Scheduled<Void>?

    /// Whether the task is cancelled (read at fire time).
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Schedules a one-shot task on an event loop.
    init(eventLoop: EventLoop, delay: TimeAmount, body: @escaping @Sendable () -> Void) {
        let scheduled = eventLoop.scheduleTask(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isCancelled else { return }
            body()
        }
        lock.withLock { self.scheduled = scheduled }
    }

    func cancel() {
        let armed = lock.withLock { () -> Scheduled<Void>? in
            cancelled = true
            let armed = scheduled
            scheduled = nil
            return armed
        }
        armed?.cancel()
    }

    deinit {
        cancel()
    }

}

/// NIO Repeated Task
///
/// A `RuntimeTask` driving a **fixed-rate** repeating schedule on an event loop: each occurrence is
/// scheduled at `previousDeadline + interval` independent of how long the body runs (matching the
/// `DispatchSourceTimer` cadence, unlike NIO's fixed-*delay* `scheduleRepeatedTask`). Missed occurrences
/// after a stall are **coalesced** into a single next fire (the deadline is advanced past `now` in whole
/// intervals), so a suspension does not produce a back-to-back catch-up storm.
///
/// The reschedule chain holds `self` **weakly**, so a dropped handle deinits and cancels the chain -
/// cancel-on-deinit is therefore true by construction, and dropping the handle is equivalent to `cancel()`.
///
final class NIORepeatedTask: RuntimeTask, @unchecked Sendable {

    /// The lock guarding `cancelled` and `scheduled`.
    private let lock = NSLock()

    /// The event loop the chain runs on.
    private let eventLoop: EventLoop

    /// The fixed interval between occurrences.
    private let interval: TimeAmount

    /// The body run on each occurrence.
    private let body: @Sendable () -> Void

    /// Whether the task has been cancelled.
    private var cancelled = false

    /// The currently-armed occurrence, if any.
    private var scheduled: Scheduled<Void>?

    /// Whether the task is cancelled (read by the reschedule chain before re-arming).
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Schedules a fixed-rate repeating task on an event loop.
    init(eventLoop: EventLoop, initialDelay: TimeAmount, interval: TimeAmount, body: @escaping @Sendable () -> Void) {
        self.eventLoop = eventLoop
        self.interval = interval
        self.body = body
        arm(at: .now() + initialDelay)
    }

    /// Arms the occurrence at a deadline; the fire re-arms at the next coalesced fixed-rate deadline.
    private func arm(at deadline: NIODeadline) {
        let scheduled = eventLoop.scheduleTask(deadline: deadline) { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.body()
            guard !self.isCancelled else { return }
            self.arm(at: self.nextDeadline(after: deadline))
        }
        lock.withLock {
            if cancelled {
                scheduled.cancel()
            } else {
                self.scheduled = scheduled
            }
        }
    }

    /// The next fixed-rate deadline, advanced past `now` in whole intervals if the loop fell behind.
    private func nextDeadline(after deadline: NIODeadline) -> NIODeadline {
        var next = deadline + interval
        let now = NIODeadline.now()
        if next < now {
            let behind = (now - next).nanoseconds
            let step = interval.nanoseconds
            next = next + .nanoseconds((behind / step + 1) * step)
        }
        return next
    }

    func cancel() {
        let armed = lock.withLock { () -> Scheduled<Void>? in
            cancelled = true
            let armed = scheduled
            scheduled = nil
            return armed
        }
        armed?.cancel()
    }

    deinit {
        cancel()
    }

}

/// NIO Runtime
///
/// The default `sACNRuntime`, backed by one shared NIO `EventLoop`. It provides the serial executor a
/// component actor isolates itself to (the loop's own executor), and schedules timers on that same loop.
/// This is one of the SwiftNIO-facing files (with `NIOComponentSocket` and `NetworkInterfaceResolver`);
/// component actors, the codec, and the stream layer never name NIO types.
///
final class NIORuntime: sACNRuntime {

    /// The event loop backing this runtime.
    let eventLoop: EventLoop

    /// The serial executor a component actor isolates itself to: our own `EventLoopSerialExecutor` over the
    /// loop, whose `checkIsolated()` (compiled at the package's macOS 15 / iOS 18 floor) makes synchronous
    /// in-isolation delivery (`assumeIsolated` from a timer tick or channel handler) valid. See that type
    /// for why `eventLoop.executor` cannot be used here.
    private let executor: EventLoopSerialExecutor

    var serialExecutor: any SerialExecutor { executor }

    /// Creates a runtime over an event loop.
    ///
    /// - Parameters:
    ///    - eventLoop: The event loop to run on. Defaults to the shared singleton group's next loop, so
    ///      all runtimes (like all sockets today) share the singleton group's threads.
    ///
    init(eventLoop: EventLoop = MultiThreadedEventLoopGroup.singleton.next()) {
        self.eventLoop = eventLoop
        self.executor = EventLoopSerialExecutor(eventLoop: eventLoop)
    }

    func scheduleRepeated(after: Duration, every: Duration, _ body: @escaping @Sendable () -> Void) -> any RuntimeTask {
        precondition(after >= .zero, "a schedule delay must not be negative")
        precondition(every > .zero, "a repeated schedule interval must be positive")
        return NIORepeatedTask(eventLoop: eventLoop, initialDelay: TimeAmount(after), interval: TimeAmount(every), body: body)
    }

    func scheduleOnce(after: Duration, _ body: @escaping @Sendable () -> Void) -> any RuntimeTask {
        precondition(after >= .zero, "a schedule delay must not be negative")
        return NIOOneShotTask(eventLoop: eventLoop, delay: TimeAmount(after), body: body)
    }

    func makeSocket(type: ComponentSocketType, ipMode: sACNIPMode, port: UInt16) -> ComponentSocket {
        NIOComponentSocket(type: type, ipMode: ipMode, port: port, eventLoop: eventLoop)
    }

}
