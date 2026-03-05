import CoreGraphics
import Foundation

enum RenderSizing {
    static let fixed720p = CGSize(width: 1280, height: 720)
    static let fixed1080p = CGSize(width: 1920, height: 1080)
    static let fixed4K = CGSize(width: 3840, height: 2160)
    static let smartCandidateSizes = [fixed720p, fixed1080p, fixed4K]
    static let defaultSize = fixed1080p

    static func renderSize(for mediaItems: [MediaItem], policy: ResolutionPolicy) -> CGSize {
        switch policy.normalized {
        case .fixed720p:
            return fixed720p
        case .fixed1080p:
            return fixed1080p
        case .fixed4K:
            return fixed4K
        case .smart:
            return smartRenderSize(for: mediaItems)
        case .matchSourceMax:
            return smartRenderSize(for: mediaItems)
        }
    }

    static func renderSize(for timeline: Timeline, policy: ResolutionPolicy) -> CGSize {
        let mediaItems = timeline.segments.compactMap { segment -> MediaItem? in
            if case let .media(item) = segment.asset {
                return item
            }
            return nil
        }
        return renderSize(for: mediaItems, policy: policy)
    }

    static func smartRenderSize(for mediaItems: [MediaItem]) -> CGSize {
        guard !mediaItems.isEmpty else {
            return defaultSize
        }

        for candidate in smartCandidateSizes {
            if mediaItems.allSatisfy({ aspectFitScale(sourceSize: sanitizedSize($0.pixelSize), into: candidate) >= 1.0 }) {
                return candidate
            }
        }

        return fixed4K
    }

    static func aspectFitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let safeRenderSize = sanitizedSize(renderSize)
        let sourceBounds = CGRect(origin: .zero, size: sanitizedSize(naturalSize))
        let orientedBounds = sourceBounds.applying(preferredTransform)
        let orientedSize = CGSize(width: abs(orientedBounds.width), height: abs(orientedBounds.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else {
            return preferredTransform
        }

        let scale = aspectFitScale(sourceSize: orientedSize, into: safeRenderSize)
        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let horizontalInset = (safeRenderSize.width - scaledSize.width) / 2.0
        let verticalInset = (safeRenderSize.height - scaledSize.height) / 2.0

        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -orientedBounds.minX, y: -orientedBounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: horizontalInset, y: verticalInset))
    }

    static func aspectFitScale(sourceSize: CGSize, into renderSize: CGSize) -> CGFloat {
        let safeSource = sanitizedSize(sourceSize)
        let safeRenderSize = sanitizedSize(renderSize)
        return min(safeRenderSize.width / safeSource.width, safeRenderSize.height / safeSource.height)
    }

    private static func sanitizedSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }
}
