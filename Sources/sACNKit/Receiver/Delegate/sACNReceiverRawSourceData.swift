//
//  sACNReceiverRawSourceData.swift
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

/// sACN Receiver Raw Source Data.
///
/// Data received from a source.
public struct sACNReceiverRawSourceData {
    
    /// The source CID.
    public var cid: UUID
    
    /// The name of the source.
    public var name: String
    
    /// The hostname of the source.
    public var hostname: String
    
    /// The universe received.
    public var universe: UInt16
    
    /// The universe priority received.
    public var priority: UInt8
    
    /// Whether this is preview data.
    public var preview: Bool
    
    /// Whether the sampling is occuring.
    ///
    /// A receiver of data for a source that is still sampling may wish to ignore it.
    public var isSampling: Bool
    
    /// The DMX512-A START code.
    public var startCode: DMX.STARTCode
    
    /// The number of values.
    public var valuesCount: Int

    /// The values received from this source.
    /// This may be less than 512.
    public var values: [UInt8]
    
}
