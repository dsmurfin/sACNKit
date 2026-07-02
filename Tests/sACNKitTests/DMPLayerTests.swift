import Foundation
import Testing

@testable import sACNKit

@Suite("DMPLayer")
struct DMPLayerTests {

    /// The test DMP Layer data.
    static let testDMPLayerData: Data = DMPLayer.createAsData(startCode: .perAddressPriority, values: [50] + Array(repeating: 0, count: 511))

    @Test("Creating a DMP layer produces the expected byte layout")
    func createDMPLayer() {
        let expected = "720b02a1000000010201dd" + "32" + Array(repeating: "00", count: 511).joined()
        #expect(Self.testDMPLayerData.hexEncodedString() == expected)
    }

    @Test("Replacing DMP layer values updates only the value region")
    func replaceValuesRange() {
        var layer = Self.testDMPLayerData
        layer.replacingDMPLayerValues(with: [255, 254] + Array(repeating: 0, count: 510))
        let expected = "720b02a1000000010201dd" + "fffe" + Array(repeating: "00", count: 510).joined()
        #expect(layer.hexEncodedString() == expected)
    }

}
