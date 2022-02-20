//
//  RootLayer.swift
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

/// Root Layer
///
/// Implements the Root Layer and handles creation and parsing.
///
struct RootLayer {
    
    /// The offset at which length counting starts.
    static let lengthCountOffset = Offset.flagsAndLength.rawValue
    
    /// The preamble size.
    private static let preambleSize = Data([0x00, 0x10])
    
    /// The postamble size.
    private static let postambleSize = Data([0x00, 0x00])
    
    /// The packet identifier which begins every sACN message.
    private static let packetIdentifier = Data([0x41, 0x53, 0x43, 0x2d, 0x45, 0x31, 0x2e, 0x31, 0x37, 0x00, 0x00, 0x00])
    
    /// The flags and length. 0x726e: 26e = 622 (starting octet 16) = 638.
    private static let flagsAndLength = Data([0x72, 0x6e])

    /// Root Layer Vectors
    ///
    /// Enumerates the supported Vectors for this layer.
    ///
    enum Vector: UInt32 {
        /// Contains a  `DataFramingLayer`.
        case data = 0x00000004
        /// Contains a  `ExtendedFramingLayer`.
        case extended = 0x00000008
    }
    
    /// Root Layer Data Offsets
    ///
    /// Enumerates the data offset for each field in this layer.
    ///
    enum Offset: Int {
        case preamble = 0
        case postAmble = 2
        case acnPacketIdentifier = 4
        case flagsAndLength = 16
        case vector = 18
        case cid = 22
        case data = 38
    }
    
    /// The vector describing the data in the layer.
    private var vector: Vector
    
    /// A globally unique identifier (UUID) representing the `Source`, compliant with RFC 4122.
    var cid: UUID
    
    /// The data contained in the layer.
    private var data: Data
    
    /// Creates a Root Layer as Data.
    ///
    /// - Parameters:
    ///    - vector: The vector for this layer.
    ///    - cid: The CID of this Source.
    ///
    /// - Returns: A `RootLayer` as a `Data` object.
    ///
    static func createAsData(vector: Vector, cid: UUID) -> Data {
        var data = Data()
        data.append(contentsOf: RootLayer.preambleSize)
        data.append(contentsOf: RootLayer.postambleSize)
        data.append(contentsOf: RootLayer.packetIdentifier)
        data.append(contentsOf: RootLayer.flagsAndLength)
        data.append(vector.rawValue.data)
        data.append(cid.data)
        return data
    }
    
    /// Attempts to create a Root Layer from the data.
    ///
    /// - Parameters:
    ///    - data: The data to be parsed.
    ///
    /// - Throws: An error of type `RootLayerValidationError`
    ///
    /// - Returns: A valid `RootLayer`.
    ///
    static func parse(fromData data: Data) throws -> Self {
        guard data.count > Offset.data.rawValue else { throw RootLayerValidationError.lengthOutOfRange }
        
        // the preamble size
        guard data[...(Offset.postAmble.rawValue-1)] == Self.preambleSize else {
            throw RootLayerValidationError.invalidPreamblePostambleSize
        }
        // the postamble size
        guard data[Offset.postAmble.rawValue...Offset.acnPacketIdentifier.rawValue-1] == Self.postambleSize else {
            throw RootLayerValidationError.invalidPreamblePostambleSize
        }
        // the packet identifier
        guard data[Offset.acnPacketIdentifier.rawValue...Offset.flagsAndLength.rawValue-1] == Self.packetIdentifier else {
            throw RootLayerValidationError.invalidPacketIdentifier
        }
        // the flags and length
        // TODO: This needs to be checked for universe discovery
        guard data[Offset.flagsAndLength.rawValue...Offset.vector.rawValue-1] == Self.flagsAndLength else {
            throw RootLayerValidationError.invalidFlagsAndLength
        }
        // the vector for this message
        guard let vector: UInt32 = data.toUInt32(atOffset: Offset.vector.rawValue) else {
            throw RootLayerValidationError.unableToParse(field: "Vector")
        }
        guard let validVector = Vector.init(rawValue: vector) else {
            throw RootLayerValidationError.invalidVector(vector)
        }
        // the cid of the source
        guard let cid: UUID = data.toUUID(atOffset: Offset.cid.rawValue) else {
            throw RootLayerValidationError.unableToParse(field: "CID")
        }
        // layer data
        let data = data.subdata(in: Offset.data.rawValue..<data.count)
        
        return Self(vector: validVector, cid: cid, data: data)
    }
    
}

/// Root Layer Data Extension
///
/// Extensions for modifying fields within an existing `RootLayer` stored as `Data`.
///
internal extension Data {
    /// Replaces the `RootLayer` Flags and Length.
    ///
    /// - Parameters:
    ///    - length: The length to be replaced in the layer.
    ///
    mutating func replacingRootLayerFlagsAndLength(with length: UInt16) {
        let flagsAndLength = FlagsAndLength.fromLength(length)
        self.replaceSubrange(RootLayer.Offset.flagsAndLength.rawValue...RootLayer.Offset.flagsAndLength.rawValue+1, with: flagsAndLength.data)
    }
}

/// Root Layer Validation Error
///
/// Enumerates all possible `RootLayer` parsing errors.
///
enum RootLayerValidationError: LocalizedError {
    
    /// The data is of insufficient length.
    case lengthOutOfRange
    
    /// The preamble or postamble size does not match that specified for E1.31.
    case invalidPreamblePostambleSize
    
    /// The packet identifier does not match that specified for E1.31.
    case invalidPacketIdentifier
    
    /// The flags and length does not match that specified for E1.31.
    case invalidFlagsAndLength
    
    /// The `Vector` is not recognized.
    case invalidVector(_ vector: UInt32)
    
    /// A field could not be parsed from the data.
    case unableToParse(field: String)

    /// A human-readable description of the error useful for logging purposes.
    var logDescription: String {
        switch self {
        case .lengthOutOfRange:
            return "Invalid Length for Root Layer."
        case .invalidPreamblePostambleSize:
            return "Invalid Preamble or Postamble Size in Root Layer."
        case .invalidPacketIdentifier:
            return "Invalid Packet Identifier in Root Layer."
        case .invalidFlagsAndLength:
            return "Invalid Flags & Length in Root Layer."
        case let .invalidVector(vector):
            return "Invalid Vector \(vector) in Root Layer."
        case let .unableToParse(field):
            return "Unable to parse \(field) in Root Layer."
        }
    }
        
}
