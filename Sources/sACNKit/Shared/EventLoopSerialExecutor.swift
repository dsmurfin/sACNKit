//
//  EventLoopSerialExecutor.swift
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

import NIOCore

/// Event Loop Serial Executor
///
/// A `SerialExecutor` that runs actor jobs on a NIO `EventLoop`, so a component actor can isolate itself to
/// the loop and re-enter isolation **synchronously** (`assumeIsolated`) from raw event-loop closures - timer
/// ticks and channel handlers - with no `Task` hop.
///
/// We provide our own rather than using `eventLoop.executor`: `NIOSerialEventLoopExecutor.checkIsolated()`
/// is `@available(macOS 15+)` inside SwiftNIO's precompiled module, and reached through an
/// `any SerialExecutor` existential it resolves to the stdlib default `checkIsolated()`, which traps
/// unconditionally (`_Concurrency/Executor.swift`). This type, compiled at the package's macOS 15 / iOS 18
/// floor, implements `checkIsolated()` directly against `preconditionInEventLoop`, so `assumeIsolated` from
/// the loop is valid.
///
final class EventLoopSerialExecutor: SerialExecutor {

    /// The event loop actor jobs run on.
    private let eventLoop: EventLoop

    /// Creates an executor over an event loop.
    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        eventLoop.execute {
            unownedJob.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(complexEquality: self)
    }

    func isSameExclusiveExecutionContext(other: EventLoopSerialExecutor) -> Bool {
        eventLoop === other.eventLoop
    }

    func checkIsolated() {
        eventLoop.preconditionInEventLoop()
    }

}
