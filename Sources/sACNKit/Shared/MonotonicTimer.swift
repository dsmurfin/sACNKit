//
//  MonotonicTimer.swift
//
//  Copyright (c) 2023 Daniel Murfin
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

/// Monotonic Timer
///
class MonotonicTimer {

    /// The time at which this timer was reset.
    private var resetTime: UInt64

    /// The timer's timeout interval.
    private var interval: UInt64
    
    /// Initializes the timer.
    ///
    /// The timer will initialize in an expired state.
    ///
    /// - Parameters:
    ///    - interval: The interval in milliseconds.
    ///
    init() {
        self.resetTime =  Self.getMilliseconds()
        self.interval = 0
    }
    
    /// Starts this timer with an interval in milliseconds.
    ///
    /// Starting the timer with an interval of 0 means it will instantly be expired.
    ///
    /// - Parameters:
    ///    - interval: The interval in milliseconds.
    ///
    func start(interval: UInt64) {
        self.resetTime = Self.getMilliseconds()
        self.interval = UInt64(interval)
    }
    
    /// Resets this timer with the previously defined interval.
    func reset() {
        resetTime =  Self.getMilliseconds()
    }
    
    func timeElapsed() -> UInt64 {
        Self.getMilliseconds()-resetTime
    }
    
    /// Checks if this timer has expired.
    ///
    /// - Returns: Whether the timer has expired.
    ///
    func isExpired() -> Bool {
        return interval == 0 || Self.getMilliseconds() - resetTime > interval
    }
    
    /// Returns the amount of time remaining.
    ///
    /// - Returns: The time remaining in milliseconds.
    ///
    func timeRemaining() -> UInt64 {
        if interval != 0 {
            let currentMilliseconds = Self.getMilliseconds()
            if currentMilliseconds - resetTime < interval {
                return resetTime + interval - currentMilliseconds
            }
        }
        return 0
    }
    
    /// Gets the clock time in milliseconds.
    private static func getMilliseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000
    }
    
}
