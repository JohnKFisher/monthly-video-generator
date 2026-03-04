import AVFoundation
import Foundation

public final class AVFoundationRenderEngine {
    private var currentSession: AVAssetExportSession?
    private let stillImageClipFactory: StillImageClipFactory

    public init(stillImageClipFactory: StillImageClipFactory = StillImageClipFactory()) {
        self.stillImageClipFactory = stillImageClipFactory
    }

    public func cancelCurrentRender() {
        currentSession?.cancelExport()
    }

    public func render(
        timeline: Timeline,
        style: StyleProfile,
        exportProfile: ExportProfile,
        outputTarget: OutputTarget,
        photoMaterializer: PhotoAssetMaterializing?,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> URL {
        guard !timeline.segments.isEmpty else {
            throw RenderError.noRenderableMedia
        }

        let diagnostics = RenderDiagnostics()
        diagnostics.add("Render started")
        diagnostics.add("Timeline segments: \(timeline.segments.count)")
        diagnostics.add("Style: title=\(style.openingTitle ?? "none"), titleDuration=\(style.titleDurationSeconds), crossfade=\(style.crossfadeDurationSeconds), stillDuration=\(style.stillImageDurationSeconds)")
        diagnostics.add("Export profile: container=\(exportProfile.container.rawValue), codec=\(exportProfile.videoCodec.rawValue), resolution=\(exportProfile.resolution), dynamicRange=\(exportProfile.dynamicRange.rawValue), audioLayout=\(exportProfile.audioLayout.rawValue), bitrate=\(exportProfile.bitrateMode.rawValue)")

        let renderSize = resolveRenderSize(from: timeline, policy: exportProfile.resolution)
        diagnostics.add("Render size: \(Int(renderSize.width))x\(Int(renderSize.height))")
        var temporaryURLs: [URL] = []
        defer {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            let clips = try await materializeInputClips(
                segments: timeline.segments,
                renderSize: renderSize,
                photoMaterializer: photoMaterializer,
                temporaryURLs: &temporaryURLs,
                diagnostics: diagnostics
            )

            guard !clips.isEmpty else {
                throw RenderError.noRenderableMedia
            }

            let composition = AVMutableComposition()
            guard
                let firstVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                let secondVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                let firstAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                let secondAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                throw RenderError.exportFailed("Failed to allocate composition tracks")
            }

            let videoTracks = [firstVideoTrack, secondVideoTrack]
            let audioTracks = [firstAudioTrack, secondAudioTrack]

            let transitionDuration = effectiveTransitionDuration(clips: clips, requestedSeconds: style.crossfadeDurationSeconds)
            diagnostics.add("Transition duration resolved: \(format(transitionDuration))")
            var clipStartTimes: [CMTime] = []
            var cursor = CMTime.zero

            for (index, clip) in clips.enumerated() {
                clipStartTimes.append(cursor)
                let trackIndex = index % 2
                let videoSourceStart = validStartTime(clip.videoTrackTimeRange?.start)
                let videoAvailableDuration = clip.videoTrackTimeRange?.duration
                let insertDuration = minPositiveDuration(clip.duration, clip.videoTrackDuration, videoAvailableDuration) ?? clip.duration
                let insertRange = CMTimeRange(start: videoSourceStart, duration: insertDuration)
                diagnostics.add("Video insert attempt index=\(index) source=\(clip.sourceDescription) targetTrack=\(trackIndex) at=\(format(cursor)) range=\(format(insertRange)) sourceTrackRange=\(format(clip.videoTrackTimeRange)) sourceAsset=\(clip.assetURL.path)")

                do {
                    try videoTracks[trackIndex].insertTimeRange(insertRange, of: clip.videoTrack, at: cursor)
                } catch {
                    diagnostics.add("Video insertion failed at index \(index): \(describe(error))")
                    throw RenderError.exportFailed("Video track insertion failed for \(clip.sourceDescription) at index \(index). \(describe(error))")
                }

                if clip.includeAudio, let audioTrack = clip.audioTrack {
                    let audioSourceStart = validStartTime(clip.audioTrackTimeRange?.start)
                    let audioAvailableDuration = clip.audioTrackTimeRange?.duration
                    let audioDuration = minPositiveDuration(clip.duration, clip.audioTrackDuration, audioAvailableDuration) ?? clip.duration
                    let audioRange = CMTimeRange(start: audioSourceStart, duration: audioDuration)
                    diagnostics.add("Audio insert attempt index=\(index) source=\(clip.sourceDescription) targetTrack=\(trackIndex) at=\(format(cursor)) range=\(format(audioRange)) sourceTrackRange=\(format(clip.audioTrackTimeRange))")
                    do {
                        try audioTracks[trackIndex].insertTimeRange(audioRange, of: audioTrack, at: cursor)
                    } catch {
                        diagnostics.add("Audio insertion failed at index \(index): \(describe(error))")
                        throw RenderError.exportFailed("Audio track insertion failed for \(clip.sourceDescription) at index \(index). \(describe(error))")
                    }
                }

                cursor = add(cursor, insertDuration)
                if index < clips.count - 1, transitionDuration > .zero {
                    cursor = subtract(cursor, transitionDuration)
                }
            }

            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            videoComposition.instructions = buildInstructions(
                clips: clips,
                clipStartTimes: clipStartTimes,
                transitionDuration: transitionDuration,
                compositionTracks: videoTracks
            )
            let colorConfiguration = colorConfiguration(for: exportProfile.dynamicRange)
            videoComposition.colorPrimaries = colorConfiguration.colorPrimaries
            videoComposition.colorTransferFunction = colorConfiguration.colorTransferFunction
            videoComposition.colorYCbCrMatrix = colorConfiguration.colorYCbCrMatrix
            diagnostics.add(
                "Video composition color properties: primaries=\(colorConfiguration.colorPrimaries), " +
                "transfer=\(colorConfiguration.colorTransferFunction), matrix=\(colorConfiguration.colorYCbCrMatrix)"
            )

            let outputURL = try OutputPathResolver.resolveUniqueURL(target: outputTarget, container: exportProfile.container)
            diagnostics.add("Resolved output URL: \(outputURL.path)")
            let presetName = bestPreset(for: exportProfile, composition: composition)
            diagnostics.add("Selected export preset: \(presetName)")
            guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
                throw RenderError.exportSessionUnavailable
            }

            currentSession = session
            session.outputURL = outputURL
            session.outputFileType = preferredFileType(container: exportProfile.container, session: session)
            diagnostics.add("Selected output file type: \(session.outputFileType?.rawValue ?? "nil")")
            session.shouldOptimizeForNetworkUse = false
            session.videoComposition = videoComposition

            progressHandler?(0.01)
            try await export(session: session)
            progressHandler?(1.0)
            currentSession = nil

            diagnostics.add("Render completed successfully")
            return outputURL
        } catch {
            currentSession = nil
            diagnostics.add("Render failed with error: \(describe(error))")
            let diagnosticURL = writeDiagnosticsFile(
                diagnostics.renderReport(for: error),
                outputTarget: outputTarget
            )
            let baseMessage = userFacingMessage(from: error)
            if let diagnosticURL {
                throw RenderError.exportFailed("\(baseMessage)\nDiagnostics file: \(diagnosticURL.path)")
            }
            throw RenderError.exportFailed(baseMessage)
        }
    }

    private func buildInstructions(
        clips: [InputClip],
        clipStartTimes: [CMTime],
        transitionDuration: CMTime,
        compositionTracks: [AVCompositionTrack]
    ) -> [AVVideoCompositionInstructionProtocol] {
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for index in clips.indices {
            let clip = clips[index]
            var passStart = clipStartTimes[index]
            var passDuration = clip.duration

            if transitionDuration > .zero {
                if index > 0 {
                    passStart = add(passStart, transitionDuration)
                    passDuration = subtract(passDuration, transitionDuration)
                }
                if index < clips.count - 1 {
                    passDuration = subtract(passDuration, transitionDuration)
                }
            }

            if passDuration > .zero {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: passStart, duration: passDuration)

                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTracks[index % 2])
                layerInstruction.setTransform(clip.preferredTransform, at: passStart)
                instruction.layerInstructions = [layerInstruction]
                instructions.append(instruction)
            }

            if index < clips.count - 1, transitionDuration > .zero {
                let transitionStart = subtract(add(clipStartTimes[index], clip.duration), transitionDuration)
                let transitionInstruction = AVMutableVideoCompositionInstruction()
                transitionInstruction.timeRange = CMTimeRange(start: transitionStart, duration: transitionDuration)

                let fromTrack = compositionTracks[index % 2]
                let toTrack = compositionTracks[(index + 1) % 2]

                let fromLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: fromTrack)
                fromLayer.setTransform(clips[index].preferredTransform, at: transitionStart)
                fromLayer.setOpacityRamp(
                    fromStartOpacity: 1.0,
                    toEndOpacity: 0.0,
                    timeRange: transitionInstruction.timeRange
                )

                let toLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: toTrack)
                toLayer.setTransform(clips[index + 1].preferredTransform, at: transitionStart)
                toLayer.setOpacityRamp(
                    fromStartOpacity: 0.0,
                    toEndOpacity: 1.0,
                    timeRange: transitionInstruction.timeRange
                )

                transitionInstruction.layerInstructions = [toLayer, fromLayer]
                instructions.append(transitionInstruction)
            }
        }

        return instructions.sorted {
            $0.timeRange.start < $1.timeRange.start
        }
    }

    private func materializeInputClips(
        segments: [TimelineSegment],
        renderSize: CGSize,
        photoMaterializer: PhotoAssetMaterializing?,
        temporaryURLs: inout [URL],
        diagnostics: RenderDiagnostics
    ) async throws -> [InputClip] {
        var clips: [InputClip] = []

        for segment in segments {
            switch segment.asset {
            case let .titleCard(title):
                let titleURL = try await stillImageClipFactory.makeTitleCardClip(title: title, duration: segment.duration, renderSize: renderSize)
                temporaryURLs.append(titleURL)
                diagnostics.add("Materialized title card clip at \(titleURL.path) for title '\(title)'")
                if let clip = try await makeClip(
                    assetURL: titleURL,
                    fallbackDuration: segment.duration,
                    includeAudio: false,
                    sourceDescription: "title card '\(title)'",
                    diagnostics: diagnostics,
                    isTemporary: true
                ) {
                    clips.append(clip)
                }

            case let .media(item):
                switch item.type {
                case .image:
                    let sourceURL = try await resolveURL(for: item, photoMaterializer: photoMaterializer)
                    let imageClipURL = try await stillImageClipFactory.makeVideoClip(fromImageURL: sourceURL, duration: segment.duration, renderSize: renderSize)
                    temporaryURLs.append(imageClipURL)
                    diagnostics.add("Materialized still image clip for \(item.filename) at \(imageClipURL.path)")
                    if let clip = try await makeClip(
                        assetURL: imageClipURL,
                        fallbackDuration: segment.duration,
                        includeAudio: false,
                        sourceDescription: "image \(item.filename)",
                        diagnostics: diagnostics,
                        isTemporary: true
                    ) {
                        clips.append(clip)
                    }

                case .video:
                    let sourceURL = try await resolveURL(for: item, photoMaterializer: photoMaterializer)
                    diagnostics.add("Using source video clip \(sourceURL.path) for \(item.filename)")
                    if let clip = try await makeClip(
                        assetURL: sourceURL,
                        fallbackDuration: segment.duration,
                        includeAudio: true,
                        sourceDescription: "video \(item.filename)",
                        diagnostics: diagnostics,
                        isTemporary: false
                    ) {
                        clips.append(clip)
                    }
                }
            }
        }

        return clips
    }

    private func resolveURL(for item: MediaItem, photoMaterializer: PhotoAssetMaterializing?) async throws -> URL {
        switch item.locator {
        case let .file(url):
            return url
        case let .photoAsset(localIdentifier):
            guard let photoMaterializer else {
                throw RenderError.unsupportedPhotoAssetWithoutMaterializer(localIdentifier)
            }
            return try await photoMaterializer.materializePhotoAsset(localIdentifier: localIdentifier, preferredFilename: item.filename)
        }
    }

    private func makeClip(
        assetURL: URL,
        fallbackDuration: CMTime,
        includeAudio: Bool,
        sourceDescription: String,
        diagnostics: RenderDiagnostics,
        isTemporary: Bool
    ) async throws -> InputClip? {
        let asset = AVURLAsset(url: assetURL)
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw RenderError.exportFailed("Unable to load video tracks for \(sourceDescription). \(describe(error))")
        }

        guard let videoTrack = videoTracks.first else {
            throw RenderError.exportFailed("No video tracks found for \(sourceDescription).")
        }

        let assetDuration: CMTime
        do {
            assetDuration = (try await asset.load(.duration))
        } catch {
            throw RenderError.exportFailed("Unable to load duration for \(sourceDescription). \(describe(error))")
        }

        let videoTrackRange = (try? await videoTrack.load(.timeRange))
        let videoTrackDuration = videoTrackRange?.duration
        let clipDuration = smallestPositiveDuration([fallbackDuration, assetDuration, videoTrackDuration]) ?? fallbackDuration
        guard clipDuration > .zero else {
            throw RenderError.exportFailed("Clip duration is invalid for \(sourceDescription).")
        }
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity

        let audioTrack = includeAudio ? (try? await asset.loadTracks(withMediaType: .audio).first) : nil
        let audioTrackDuration: CMTime?
        let audioTrackTimeRange: CMTimeRange?
        if let audioTrack {
            let timeRange = try? await audioTrack.load(.timeRange)
            audioTrackDuration = timeRange?.duration
            audioTrackTimeRange = timeRange
        } else {
            audioTrackDuration = nil
            audioTrackTimeRange = nil
        }

        let codecDescription = await videoCodecDescription(for: videoTrack)

        diagnostics.add(
            "Clip ready: source=\(sourceDescription), asset=\(assetURL.path), clipDuration=\(format(clipDuration)), " +
            "assetDuration=\(format(assetDuration)), videoTrackRange=\(format(videoTrackRange)), " +
            "audioTrackRange=\(format(audioTrackTimeRange)), codec=\(codecDescription), temp=\(isTemporary)"
        )

        return InputClip(
            sourceAsset: asset,
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            assetURL: assetURL,
            videoTrackTimeRange: videoTrackRange,
            audioTrackTimeRange: audioTrackTimeRange,
            videoTrackDuration: videoTrackDuration,
            audioTrackDuration: audioTrackDuration,
            duration: clipDuration,
            preferredTransform: preferredTransform,
            naturalSize: naturalSize,
            sourceDescription: sourceDescription,
            isTemporary: isTemporary,
            includeAudio: includeAudio
        )
    }

    private func effectiveTransitionDuration(clips: [InputClip], requestedSeconds: Double) -> CMTime {
        guard clips.count > 1, requestedSeconds > 0 else {
            return .zero
        }

        let requested = CMTime(seconds: requestedSeconds, preferredTimescale: 600)
        let halfOfShortest = clips
            .map { CMTime(seconds: max($0.duration.seconds / 2.0, 0), preferredTimescale: 600) }
            .min() ?? .zero

        return minTime(requested, halfOfShortest)
    }

    private func resolveRenderSize(from timeline: Timeline, policy: ResolutionPolicy) -> CGSize {
        switch policy {
        case .fixed1080p:
            return CGSize(width: 1920, height: 1080)
        case .fixed4K:
            return CGSize(width: 3840, height: 2160)
        case .matchSourceMax:
            let mediaItems = timeline.segments.compactMap { segment -> MediaItem? in
                if case let .media(item) = segment.asset {
                    return item
                }
                return nil
            }

            let maxWidth = mediaItems.map { $0.pixelSize.width }.max() ?? 1920
            let maxHeight = mediaItems.map { $0.pixelSize.height }.max() ?? 1080

            let width = max(640, Int(maxWidth.rounded()))
            let height = max(360, Int(maxHeight.rounded()))
            return CGSize(width: width.isMultiple(of: 2) ? width : width + 1, height: height.isMultiple(of: 2) ? height : height + 1)
        }
    }

    private func bestPreset(for profile: ExportProfile, composition: AVAsset) -> String {
        let preferred = profile.videoCodec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: composition)
        if compatible.contains(preferred) {
            return preferred
        }
        return AVAssetExportPresetHighestQuality
    }

    private func preferredFileType(container: ContainerFormat, session: AVAssetExportSession) -> AVFileType {
        let preferred: AVFileType = container == .mp4 ? .mp4 : .mov
        if session.supportedFileTypes.contains(preferred) {
            return preferred
        }
        return session.supportedFileTypes.first ?? .mov
    }

    struct VideoColorConfiguration: Equatable {
        let colorPrimaries: String
        let colorTransferFunction: String
        let colorYCbCrMatrix: String
    }

    func colorConfiguration(for dynamicRange: DynamicRange) -> VideoColorConfiguration {
        switch dynamicRange {
        case .sdr:
            return VideoColorConfiguration(
                colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
                colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
                colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2
            )
        case .hdr:
            return VideoColorConfiguration(
                colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
                colorTransferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
                colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020
            )
        }
    }

    private func export(session: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume(returning: ())
                case .cancelled:
                    continuation.resume(throwing: RenderError.exportFailed("Render cancelled"))
                case .failed:
                    continuation.resume(throwing: RenderError.exportFailed(session.error?.localizedDescription ?? "Unknown export failure"))
                default:
                    continuation.resume(throwing: RenderError.exportFailed("Unexpected export status: \(session.status.rawValue)"))
                }
            }
        }
    }

    private func add(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeAdd(lhs, rhs)
    }

    private func subtract(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeSubtract(lhs, rhs)
    }

    private func minTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    private struct InputClip {
        // Keep a strong reference to the backing asset for track lifetime safety.
        let sourceAsset: AVAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let assetURL: URL
        let videoTrackTimeRange: CMTimeRange?
        let audioTrackTimeRange: CMTimeRange?
        let videoTrackDuration: CMTime?
        let audioTrackDuration: CMTime?
        let duration: CMTime
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize
        let sourceDescription: String
        let isTemporary: Bool
        let includeAudio: Bool
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let reason = nsError.localizedFailureReason ?? nsError.localizedRecoverySuggestion ?? "No additional details."
        let userInfoSummary = nsError.userInfo
            .map { key, value in "\(key)=\(value)" }
            .sorted()
            .joined(separator: ", ")
        if userInfoSummary.isEmpty {
            return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription). \(reason)"
        }
        return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription). \(reason). userInfo{\(userInfoSummary)}"
    }

    private func videoCodecDescription(for track: AVAssetTrack) async -> String {
        guard let formatDescriptions = try? await track.load(.formatDescriptions) else {
            return "unknown"
        }
        guard let firstDescription = formatDescriptions.first else {
            return "unknown"
        }
        let mediaSubType = CMFormatDescriptionGetMediaSubType(firstDescription)
        let fourcc = fourCCString(mediaSubType)
        return "\(fourcc) (\(mediaSubType))"
    }

    private func fourCCString(_ value: FourCharCode) -> String {
        let bigEndian = value.bigEndian
        let bytes: [UInt8] = [
            UInt8((bigEndian >> 24) & 0xff),
            UInt8((bigEndian >> 16) & 0xff),
            UInt8((bigEndian >> 8) & 0xff),
            UInt8(bigEndian & 0xff)
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
        if printable, let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    private func smallestPositiveDuration(_ values: [CMTime?]) -> CMTime? {
        values
            .compactMap { $0 }
            .filter { isPositiveFiniteTime($0) }
            .min { CMTimeCompare($0, $1) < 0 }
    }

    private func minPositiveDuration(_ values: CMTime?...) -> CMTime? {
        smallestPositiveDuration(values)
    }

    private func isPositiveFiniteTime(_ value: CMTime) -> Bool {
        value.isValid && value.isNumeric && value.seconds.isFinite && value > .zero
    }

    private func validStartTime(_ time: CMTime?) -> CMTime {
        guard let time else { return .zero }
        guard time.isValid, time.isNumeric, time.seconds.isFinite else { return .zero }
        return time
    }

    private func format(_ time: CMTime) -> String {
        guard time.isValid else { return "invalid" }
        guard time.isNumeric else { return "non-numeric" }
        return String(format: "%.6fs", time.seconds)
    }

    private func format(_ timeRange: CMTimeRange?) -> String {
        guard let timeRange else { return "nil" }
        return "[start=\(format(timeRange.start)), duration=\(format(timeRange.duration)), end=\(format(timeRange.end))]"
    }

    private func userFacingMessage(from error: Error) -> String {
        if let renderError = error as? RenderError {
            switch renderError {
            case .exportFailed(let message):
                return message
            default:
                return renderError.errorDescription ?? describe(error)
            }
        }
        return describe(error)
    }

    private func writeDiagnosticsFile(_ report: String, outputTarget: OutputTarget) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        let filename = "export-diagnostics-\(formatter.string(from: Date())).log"

        let fileManager = FileManager.default
        let preferredDirectory = outputTarget.directory
        let fallbackDirectory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator/Diagnostics", isDirectory: true)

        for directory in [preferredDirectory, fallbackDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileURL = directory.appendingPathComponent(filename)
                guard let data = report.data(using: .utf8) else {
                    continue
                }
                try data.write(to: fileURL)
                return fileURL
            } catch {
                continue
            }
        }
        return nil
    }

    private final class RenderDiagnostics {
        private let startedAt = Date()
        private let runID = UUID().uuidString
        private var lines: [String] = []

        func add(_ line: String) {
            lines.append("[\(timestamp())] \(line)")
        }

        func renderReport(for error: Error) -> String {
            var reportLines: [String] = []
            reportLines.append("MonthlyVideoGenerator export diagnostics")
            reportLines.append("run_id=\(runID)")
            reportLines.append("started_at=\(startedAt.ISO8601Format())")
            reportLines.append("ended_at=\(Date().ISO8601Format())")
            reportLines.append("error=\(error)")
            reportLines.append("")
            reportLines.append(contentsOf: lines)
            reportLines.append("")
            reportLines.append("end_of_report")
            return reportLines.joined(separator: "\n")
        }

        private func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            formatter.timeZone = .current
            return formatter.string(from: Date())
        }
    }
}
