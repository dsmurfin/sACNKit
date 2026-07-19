//
//  sACNDataOptions.swift
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

/// sACN Data Options
///
/// The options bit field of a received E1.31 Data Framing Layer, surfaced on `sACNReceiverRawSourceData`.
///
/// `preview` is also available as a dedicated `Bool` on the source data (and drives preview filtering); this
/// set exposes the full options field for callers that need `terminated` or `forceSynchronization`.
///
public struct sACNDataOptions: OptionSet, Sendable {

    /// The raw options byte, exactly as received on the wire.
    public let rawValue: UInt8

    /// Creates an options set from a raw options byte.
    ///
    /// - Parameters:
    ///    - rawValue: The raw options byte.
    ///
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The data is intended for use in visualisation or media-server preview applications, and should not be
    /// used to drive live fixtures.
    public static let preview = sACNDataOptions(rawValue: 1 << 7)

    /// The source has terminated transmission of this universe.
    public static let terminated = sACNDataOptions(rawValue: 1 << 6)

    /// The source is requesting that receivers hold this data until a synchronization message arrives.
    public static let forceSynchronization = sACNDataOptions(rawValue: 1 << 5)

}
