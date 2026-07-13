import Foundation

@testable import sACNKit

/// Builds a complete sACN data packet (root + framing + DMP) for injection into receiver seams.
func sACNTestDataPacket(
    cid: UUID, name: String = "Test Source", universe: UInt16 = 1, sequence: UInt8, priority: UInt8 = 100,
    options: DataFramingLayer.Options = .none, startCode: DMX.STARTCode = .null, values: [UInt8] = Array(repeating: 0, count: 512)
) -> Data {
    var framing = DataFramingLayer.createAsData(nameData: Source.buildNameData(from: name), priority: priority, universe: universe)
    framing.replacingSequence(with: sequence)
    framing.replacingOptions(with: options)
    framing.append(DMPLayer.createAsData(startCode: startCode, values: values))
    var packet = RootLayer.createAsData(vector: .data, cid: cid)
    packet.append(framing)
    packet.replacingRootLayerFlagsAndLength(with: UInt16(packet.count - RootLayer.Offset.flagsAndLength.rawValue))

    // the layer builders bake 512-slot lengths; patch the framing and DMP
    // flags-and-length and the DMP property value count so the packet is
    // valid for any value count
    let framingOffset = RootLayer.Offset.data.rawValue
    packet.replaceSubrange(
        framingOffset...framingOffset + 1, with: FlagsAndLength.fromLength(UInt16(packet.count - framingOffset)).data)
    let dmpOffset = framingOffset + DataFramingLayer.Offset.data.rawValue
    packet.replaceSubrange(
        dmpOffset...dmpOffset + 1, with: FlagsAndLength.fromLength(UInt16(packet.count - dmpOffset)).data)
    let propertyValueCountOffset = dmpOffset + DMPLayer.Offset.propertyValueCount.rawValue
    packet.replaceSubrange(propertyValueCountOffset...propertyValueCountOffset + 1, with: UInt16(values.count + 1).data)
    return packet
}
