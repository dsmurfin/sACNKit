//
//  Priority.swift
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

/// UInt8 Extension
///
/// Priority Extensions to `UInt8`.
internal extension UInt8 {
    /// The minimum permitted value for priority.
    static let minPriority: UInt8 = 0
    
    /// The maximum permitted value for priority.
    static let maxPriority: UInt8 = 200
    
    /// The default value for priority; used where not specified.
    static let defaultPriority: UInt8 = 100
    
    /// The range of valid priorities.
    static let validPriorities: ClosedRange<UInt8> = minPriority...maxPriority
    
    /// Determines whether this priority is valid.
    ///
    /// - Returns: Whether this priority is valid.
    ///
    func validPriority() -> Bool {
        return UInt8.minPriority...UInt8.maxPriority ~= self
    }
    
    /// Calculates the nearest valid priority to the one specified.
    ///
    /// - Returns: A valid priority nearest to the value specified.
    ///
    func nearestValidPriority() -> UInt8 {
        self < Self.minPriority ? Self.minPriority : self > Self.maxPriority ? Self.maxPriority : self
    }
}
