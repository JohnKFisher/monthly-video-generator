import AVFoundation
import Foundation

public struct RenderPreparation: @unchecked Sendable {
    public let items: [MediaItem]
    public let timeline: Timeline
    public let warnings: [String]

    public init(items: [MediaItem], timeline: Timeline, warnings: [String]) {
        self.items = items
        self.timeline = timeline
        self.warnings = warnings
    }
}

public final class RenderCoordinator: @unchecked Sendable {
    private let folderDiscoveryService: FolderMediaDiscoveryService
    private let timelineBuilder: TimelineBuilder
    private let renderEngine: AVFoundationRenderEngine
    private let longDurationWarningThresholdSeconds: Double = 20 * 60

    public init(
        folderDiscoveryService: FolderMediaDiscoveryService = FolderMediaDiscoveryService(),
        timelineBuilder: TimelineBuilder = TimelineBuilder(),
        renderEngine: AVFoundationRenderEngine = AVFoundationRenderEngine()
    ) {
        self.folderDiscoveryService = folderDiscoveryService
        self.timelineBuilder = timelineBuilder
        self.renderEngine = renderEngine
    }

    public func prepareFolderRender(request: RenderRequest) async throws -> RenderPreparation {
        guard case let .folder(path, recursive) = request.source else {
            throw RenderError.exportFailed("Folder render requested with non-folder source")
        }

        let items = try await folderDiscoveryService.discover(folderURL: path, recursive: recursive)
        return prepareFromItems(items, request: request)
    }

    public func prepareFromItems(_ items: [MediaItem], request: RenderRequest) -> RenderPreparation {
        let timeline = timelineBuilder.buildTimeline(items: items, ordering: request.ordering, style: request.style)

        var warnings: [String] = []
        if timeline.estimatedDuration.seconds >= longDurationWarningThresholdSeconds {
            warnings.append("Estimated output duration is \(formatDuration(timeline.estimatedDuration)). This may take longer to export.")
        }

        return RenderPreparation(items: items, timeline: timeline, warnings: warnings)
    }

    public func render(
        preparation: RenderPreparation,
        request: RenderRequest,
        photoMaterializer: PhotoAssetMaterializing?,
        progressHandler: ((Double) -> Void)?
    ) async throws -> URL {
        try await renderEngine.render(
            timeline: preparation.timeline,
            style: request.style,
            exportProfile: request.export,
            outputTarget: request.output,
            photoMaterializer: photoMaterializer,
            progressHandler: progressHandler
        )
    }

    public func cancelCurrentRender() {
        renderEngine.cancelCurrentRender()
    }

    private func formatDuration(_ duration: CMTime) -> String {
        let seconds = Int(duration.seconds.rounded())
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
