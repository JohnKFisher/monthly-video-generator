import Foundation

public enum RenderError: LocalizedError, CustomNSError {
    case noRenderableMedia
    case unsupportedPhotoAssetWithoutMaterializer(String)
    case exportFailed(String)
    case invalidOutputDirectory(URL)
    case exportSessionUnavailable
    case paused(String)

    public static var errorDomain: String {
        "Core.RenderError"
    }

    public var errorCode: Int {
        switch self {
        case .noRenderableMedia:
            return 0
        case .unsupportedPhotoAssetWithoutMaterializer:
            return 1
        case .exportFailed:
            return 2
        case .invalidOutputDirectory:
            return 3
        case .exportSessionUnavailable:
            return 4
        case .paused:
            return 5
        }
    }

    public var errorUserInfo: [String: Any] {
        if let errorDescription {
            return [NSLocalizedDescriptionKey: errorDescription]
        }
        return [:]
    }

    public var errorDescription: String? {
        switch self {
        case .noRenderableMedia:
            return "No renderable media was found for this request."
        case let .unsupportedPhotoAssetWithoutMaterializer(identifier):
            return "Photo asset \(identifier) cannot be rendered because no photo materializer was provided."
        case let .exportFailed(message):
            return "Export failed: \(message)"
        case let .invalidOutputDirectory(url):
            return "Unable to access output directory: \(url.path)"
        case .exportSessionUnavailable:
            return "Unable to create AVAssetExportSession for this composition."
        case let .paused(message):
            return message
        }
    }
}
