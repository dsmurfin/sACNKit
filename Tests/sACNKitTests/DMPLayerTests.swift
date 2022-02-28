import XCTest
@testable import sACNKit

final class DMPLayerTests: XCTestCase {
    
    /// The test DMP Layer data.
    static let testDMPLayerData: Data = DMPLayer.createAsData(startCode: .perAddressPriority, values: [50] + Array(repeating: 0, count: 511))
    
    /// Creates a DMP Layer.
    func testCreateDMPLayer() throws {
        let testLayer = Self.testDMPLayerData
        let expectedString = "720b02a1000000010201dd" + "32" + Array(repeating: "00", count: 511).joined()

        XCTAssertEqual(testLayer.hexEncodedString(), expectedString)
    }
    
    /// Replaces the values in a DMP Layer range.
    func testReplaceDMPLayerValuesRange() throws {
        var testLayer = Self.testDMPLayerData
        testLayer.replacingDMPLayerValues(with: [255, 254] + Array(repeating: 0, count: 510))
        let expectedString = "720b02a1000000010201dd" + "fffe" + Array(repeating: "00", count: 510).joined()

        XCTAssertEqual(testLayer.hexEncodedString(), expectedString)
    }
    
}
