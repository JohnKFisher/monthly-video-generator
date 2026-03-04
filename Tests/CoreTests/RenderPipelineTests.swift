import AVFoundation
@testable import Core
import Foundation
import XCTest

final class RenderPipelineTests: XCTestCase {
    func testLongDurationWarningIsProduced() {
        let item = MediaItem(
            id: "video",
            type: .video,
            captureDate: Date(),
            duration: CMTime(seconds: 60 * 21, preferredTimescale: 600),
            pixelSize: CGSize(width: 1920, height: 1080),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/video.mov")),
            fileSizeBytes: 1_000_000,
            filename: "video.mov"
        )

        let request = RenderRequest(
            source: .folder(path: URL(fileURLWithPath: "/tmp"), recursive: true),
            monthYear: nil,
            ordering: .captureDateAscendingStable,
            style: .stageOneDefault,
            export: .balancedDefault,
            output: OutputTarget(directory: URL(fileURLWithPath: "/tmp"), baseFilename: "x")
        )

        let coordinator = RenderCoordinator()
        let preparation = coordinator.prepareFromItems([item], request: request)

        XCTAssertFalse(preparation.warnings.isEmpty)
    }

    func testSDRColorConfigurationUsesBT709() {
        let engine = AVFoundationRenderEngine()

        let config = engine.colorConfiguration(for: .sdr)

        XCTAssertEqual(config.colorPrimaries, AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(config.colorTransferFunction, AVVideoTransferFunction_ITU_R_709_2)
        XCTAssertEqual(config.colorYCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    func testHDRColorConfigurationUsesBT2020HLG() {
        let engine = AVFoundationRenderEngine()

        let config = engine.colorConfiguration(for: .hdr)

        XCTAssertEqual(config.colorPrimaries, AVVideoColorPrimaries_ITU_R_2020)
        XCTAssertEqual(config.colorTransferFunction, AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(config.colorYCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_2020)
    }
}
