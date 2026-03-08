import AVFoundation
import Foundation

public enum MediaType: String, Codable, Sendable {
    case image
    case video
}

public enum ColorTransferFlavor: String, Codable, Sendable {
    case sdr
    case hlg
    case pq

    static func inferred(isHDR: Bool, transferFunction: String?) -> ColorTransferFlavor {
        let normalized = (transferFunction ?? "").lowercased()
        if normalized.contains("2084") || normalized.contains("pq") {
            return .pq
        }
        if normalized.contains("2100_hlg") || normalized.contains("hlg") || isHDR {
            return .hlg
        }
        return .sdr
    }
}

public enum HDRMetadataFlavor: String, Codable, Sendable {
    case none
    case gainMap
    case dolbyVision
}

public struct ColorInfo: Equatable, Codable, Sendable {
    public let isHDR: Bool
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let transferFlavor: ColorTransferFlavor
    public let hdrMetadataFlavor: HDRMetadataFlavor

    public init(
        isHDR: Bool,
        colorPrimaries: String?,
        transferFunction: String? = nil,
        transferFlavor: ColorTransferFlavor? = nil,
        hdrMetadataFlavor: HDRMetadataFlavor = .none
    ) {
        let resolvedTransferFlavor = transferFlavor ?? ColorTransferFlavor.inferred(
            isHDR: isHDR,
            transferFunction: transferFunction
        )
        let resolvedIsHDR = isHDR || resolvedTransferFlavor != .sdr || hdrMetadataFlavor != .none
        self.isHDR = resolvedIsHDR
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.transferFlavor = resolvedTransferFlavor
        self.hdrMetadataFlavor = hdrMetadataFlavor
    }

    public var usesDolbyVisionFallback: Bool {
        hdrMetadataFlavor == .dolbyVision
    }

    public var usesGainMapPromotion: Bool {
        hdrMetadataFlavor == .gainMap
    }

    public var isDisplayP3Like: Bool {
        let normalized = (colorPrimaries ?? "").lowercased()
        return normalized.contains("p3") || normalized.contains("smpte432") || normalized.contains("dci")
    }

    public static let unknown = ColorInfo(isHDR: false, colorPrimaries: nil, transferFunction: nil)

    private enum CodingKeys: String, CodingKey {
        case isHDR
        case colorPrimaries
        case transferFunction
        case transferFlavor
        case hdrMetadataFlavor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isHDR = try container.decode(Bool.self, forKey: .isHDR)
        let colorPrimaries = try container.decodeIfPresent(String.self, forKey: .colorPrimaries)
        let transferFunction = try container.decodeIfPresent(String.self, forKey: .transferFunction)
        let transferFlavor = try container.decodeIfPresent(ColorTransferFlavor.self, forKey: .transferFlavor)
        let hdrMetadataFlavor = try container.decodeIfPresent(HDRMetadataFlavor.self, forKey: .hdrMetadataFlavor) ?? .none
        self.init(
            isHDR: isHDR,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            transferFlavor: transferFlavor,
            hdrMetadataFlavor: hdrMetadataFlavor
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isHDR, forKey: .isHDR)
        try container.encodeIfPresent(colorPrimaries, forKey: .colorPrimaries)
        try container.encodeIfPresent(transferFunction, forKey: .transferFunction)
        try container.encode(transferFlavor, forKey: .transferFlavor)
        try container.encode(hdrMetadataFlavor, forKey: .hdrMetadataFlavor)
    }
}

public enum MediaLocator: Equatable, Sendable {
    case file(URL)
    case photoAsset(localIdentifier: String)
}

public struct MediaItem: Equatable, Identifiable, @unchecked Sendable {
    public let id: String
    public let type: MediaType
    public let captureDate: Date?
    public let duration: CMTime?
    public let sourceFrameRate: Double?
    public let sourceAudioChannelCount: Int?
    public let pixelSize: CGSize
    public let colorInfo: ColorInfo
    public let locator: MediaLocator
    public let fileSizeBytes: Int64?
    public let filename: String

    public init(
        id: String,
        type: MediaType,
        captureDate: Date?,
        duration: CMTime?,
        sourceFrameRate: Double? = nil,
        sourceAudioChannelCount: Int? = nil,
        pixelSize: CGSize,
        colorInfo: ColorInfo,
        locator: MediaLocator,
        fileSizeBytes: Int64?,
        filename: String
    ) {
        self.id = id
        self.type = type
        self.captureDate = captureDate
        self.duration = duration
        self.sourceFrameRate = sourceFrameRate
        self.sourceAudioChannelCount = sourceAudioChannelCount
        self.pixelSize = pixelSize
        self.colorInfo = colorInfo
        self.locator = locator
        self.fileSizeBytes = fileSizeBytes
        self.filename = filename
    }

    public var stableTieBreaker: String {
        let size = fileSizeBytes ?? -1
        return "\(filename.lowercased())::\(size)::\(id)"
    }

    public func withSourceFrameRate(_ sourceFrameRate: Double?) -> MediaItem {
        withSourceInspection(sourceFrameRate: sourceFrameRate, sourceAudioChannelCount: sourceAudioChannelCount)
    }

    public func withSourceAudioChannelCount(_ sourceAudioChannelCount: Int?) -> MediaItem {
        withSourceInspection(sourceFrameRate: sourceFrameRate, sourceAudioChannelCount: sourceAudioChannelCount)
    }

    public func withSourceInspection(
        sourceFrameRate: Double?,
        sourceAudioChannelCount: Int?
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: type,
            captureDate: captureDate,
            duration: duration,
            sourceFrameRate: sourceFrameRate,
            sourceAudioChannelCount: sourceAudioChannelCount,
            pixelSize: pixelSize,
            colorInfo: colorInfo,
            locator: locator,
            fileSizeBytes: fileSizeBytes,
            filename: filename
        )
    }
}
