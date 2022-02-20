//
//  FlagsAndLength.swift
//
//  Copyright (c) 2022 Daniel Murfin
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

/// Flags And Length
///
/// As defined in E1.31
///
enum FlagsAndLength {
    /// Combines the first 12 bits of `length` with the first 4 bits of `flags`.
    ///
    /// - Parameters:
    ///    - length: The length of the PDU. (only the first 12 bits are used).
    ///
    /// - Returns: Flags and Length.
    ///
    static func fromLength(_ length: UInt16) -> UInt16 {
        let escapedLength = length & 0b0000_1111_1111_1111
        let escapedFlags  = UInt16(0x07) << 12 & 0b1111_0000_0000_0000
        return escapedFlags | escapedLength
    }
    
    /// Extracts the length from a Flags and Length field.
    ///
    /// - Parameters:
    ///    - flagsAndLength: The flags and length.
    ///
    /// - Returns: An optional length value.
    ///
    static func toLength(from flagsAndLength: UInt16) -> UInt16? {
        let escapedLength = flagsAndLength & 0b0000_1111_1111_1111
        let escapedFlags  = flagsAndLength >> 12
        return escapedFlags == 7 ? UInt16(escapedLength) : nil
    }
}
