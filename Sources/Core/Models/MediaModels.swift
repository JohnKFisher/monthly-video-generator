import AVFoundation
import Foundation

public enum MediaType: String, Codable, Sendable {
    case image
    case video
}

public struct ColorInfo: Equatable, Codable, Sendable {
    public let isHDR: Bool
    public let colorPrimaries: String?

    public init(isHDR: Bool, colorPrimaries: String?) {
        self.isHDR = isHDR
        self.colorPrimaries = colorPrimaries
    }

    public static let unknown = ColorInfo(isHDR: false, colorPrimaries: nil)
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
}
