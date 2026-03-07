@testable import Core
import Foundation
import ImageIO
import XCTest

final class CaptureDateOverlayFactoryTests: XCTestCase {
    func testOverlayPlateIsTightlyCroppedInsteadOfFullFrame() throws {
        let factory = CaptureDateOverlayFactory()
        let renderSize = CGSize(width: 3840, height: 2160)
        let overlayURL = try factory.makeOverlayPlate(
            text: "June 14, 2023 2:33 PM",
            renderSize: renderSize
        )
        defer {
            try? FileManager.default.removeItem(at: overlayURL)
        }

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(overlayURL as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        let pixelWidth = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let pixelHeight = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)

        XCTAssertGreaterThan(pixelWidth, 0)
        XCTAssertGreaterThan(pixelHeight, 0)
        XCTAssertLessThan(pixelWidth, Int(renderSize.width / 2))
        XCTAssertLessThan(pixelHeight, Int(renderSize.height / 4))
    }
}
