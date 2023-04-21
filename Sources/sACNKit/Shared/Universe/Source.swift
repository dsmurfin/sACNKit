//
//  Source.swift
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
#if os(iOS)
import UIKit
#endif

/// Source
///
/// A stream of E1.31 Packets for a universe is said to be sent from a source.
/// Sources are uniquely identified by their CID.
struct Source: Equatable {
    
    /// The maximum source name length in bytes.
    static let sourceNameMaxBytes = 64
    
    /// A unique identifier for this source.
    var cid: UUID
    
    /// Gets the current device name.
    ///
    /// - Returns: A device name as a string.
    ///
    static func getDeviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName!
        #endif
    }
    
    /// Builds source name data for this source.
    ///
    /// - parameters:
    ///    - name: The name of the source.
    ///
    /// - Returns: A Data object.
    ///
    static func buildNameData(from name: String) -> Data {
        name.data(paddedTo: Self.sourceNameMaxBytes)
    }
    
}
