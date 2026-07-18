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

/// Builds a complete sACN universe-discovery packet (root extended + universe-discovery framing +
/// discovery layer) for one page, for injection into the discovery receiver seam. Mirrors
/// `sACNSource.updateUniverseDiscoveryMessages`.
func sACNTestDiscoveryPacket(
    cid: UUID, name: String = "Test Source", page: UInt8 = 0, lastPage: UInt8 = 0, universes: [UInt16]
) -> Data {
    var rootLayer = RootLayer.createAsData(vector: .extended, cid: cid)
    var framingLayer = UniverseDiscoveryFramingLayer.createAsData(nameData: Source.buildNameData(from: name))
    let discoveryLayer = UniverseDiscoveryLayer.createAsData(page: page, lastPage: lastPage, universeList: universes)

    framingLayer.replacingUniverseDiscoveryFramingFlagsAndLength(with: UInt16(framingLayer.count + discoveryLayer.count))
    rootLayer.replacingRootLayerFlagsAndLength(
        with: UInt16(rootLayer.count + framingLayer.count + discoveryLayer.count - RootLayer.lengthCountOffset))

    return rootLayer + framingLayer + discoveryLayer
}
