import Foundation

struct FFmpegHDRChunkSegment: Equatable, Sendable {
    let sequenceIndex: Int
    let clips: [FFmpegRenderClip]
    let expectedDurationSeconds: Double
}

struct FFmpegHDRChunkPlan: Equatable, Sendable {
    let transitionDurationSeconds: Double
    let chunks: [FFmpegHDRChunkSegment]

    var requiresChunking: Bool {
        chunks.count > 1
    }
}

struct FFmpegHDRChunkPlanner {
    static let defaultMaxClipsPerChunk = 10
    static let defaultMaxChunkDurationSeconds = 45.0

    let maxClipsPerChunk: Int
    let maxChunkDurationSeconds: Double

    init(
        maxClipsPerChunk: Int = FFmpegHDRChunkPlanner.defaultMaxClipsPerChunk,
        maxChunkDurationSeconds: Double = FFmpegHDRChunkPlanner.defaultMaxChunkDurationSeconds
    ) {
        self.maxClipsPerChunk = max(maxClipsPerChunk, 1)
        self.maxChunkDurationSeconds = max(maxChunkDurationSeconds, 0.01)
    }

    func plan(for renderPlan: FFmpegRenderPlan) -> FFmpegHDRChunkPlan {
        guard !renderPlan.clips.isEmpty else {
            return FFmpegHDRChunkPlan(transitionDurationSeconds: renderPlan.transitionDurationSeconds, chunks: [])
        }

        var segments: [FFmpegHDRChunkSegment] = []
        var workingClips: [FFmpegRenderClip] = []
        var nextSequenceIndex = 0

        for clip in renderPlan.clips {
            let proposedClips = workingClips + [clip]
            let proposedDuration = expectedDurationSeconds(
                for: proposedClips,
                transitionDurationSeconds: renderPlan.transitionDurationSeconds
            )
            let exceedsClipLimit = proposedClips.count > maxClipsPerChunk
            let exceedsDurationLimit = proposedDuration > maxChunkDurationSeconds

            if !workingClips.isEmpty && (exceedsClipLimit || exceedsDurationLimit) {
                let duration = expectedDurationSeconds(
                    for: workingClips,
                    transitionDurationSeconds: renderPlan.transitionDurationSeconds
                )
                segments.append(
                    FFmpegHDRChunkSegment(
                        sequenceIndex: nextSequenceIndex,
                        clips: workingClips,
                        expectedDurationSeconds: duration
                    )
                )
                nextSequenceIndex += 1
                workingClips = [clip]
                continue
            }

            workingClips = proposedClips
        }

        if !workingClips.isEmpty {
            let duration = expectedDurationSeconds(
                for: workingClips,
                transitionDurationSeconds: renderPlan.transitionDurationSeconds
            )
            segments.append(
                FFmpegHDRChunkSegment(
                    sequenceIndex: nextSequenceIndex,
                    clips: workingClips,
                    expectedDurationSeconds: duration
                )
            )
        }

        return FFmpegHDRChunkPlan(
            transitionDurationSeconds: renderPlan.transitionDurationSeconds,
            chunks: segments
        )
    }

    func expectedDurationSeconds(
        for clips: [FFmpegRenderClip],
        transitionDurationSeconds: Double
    ) -> Double {
        guard !clips.isEmpty else {
            return 0.01
        }

        let total = clips.reduce(0.0) { $0 + max($1.durationSeconds, 0.01) }
        let transitions = max(transitionDurationSeconds, 0) * Double(max(clips.count - 1, 0))
        return max(total - transitions, 0.01)
    }
}

struct FFmpegHDRChunkExecutionPlan: Equatable, Sendable {
    let chunkPlan: FFmpegHDRChunkPlan
    let chunkPlans: [FFmpegRenderPlan]
    let finalPlan: FFmpegRenderPlan
}

struct FFmpegHDRChunkPipelineBuilder {
    let planner: FFmpegHDRChunkPlanner

    init(planner: FFmpegHDRChunkPlanner = FFmpegHDRChunkPlanner()) {
        self.planner = planner
    }

    func makeExecutionPlan(
        for finalPlan: FFmpegRenderPlan,
        intermediateOutputURL: (Int) -> URL
    ) -> FFmpegHDRChunkExecutionPlan? {
        guard finalPlan.dynamicRange == .hdr,
              finalPlan.videoCodec == .hevc,
              finalPlan.renderIntent == .finalDelivery else {
            return nil
        }

        let chunkPlan = planner.plan(for: finalPlan)
        guard chunkPlan.requiresChunking else {
            return nil
        }

        let chunkPlans = chunkPlan.chunks.map { chunk in
            FFmpegRenderPlan(
                clips: chunk.clips,
                transitionDurationSeconds: finalPlan.transitionDurationSeconds,
                outputURL: intermediateOutputURL(chunk.sequenceIndex),
                renderSize: finalPlan.renderSize,
                frameRate: finalPlan.frameRate,
                audioLayout: finalPlan.audioLayout,
                bitrateMode: finalPlan.bitrateMode,
                container: .mov,
                videoCodec: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: finalPlan.hdrHEVCEncoderMode,
                renderIntent: .intermediateChunk
            )
        }

        let finalClips = chunkPlan.chunks.map { chunk in
            FFmpegRenderClip(
                url: chunkPlans[chunk.sequenceIndex].outputURL,
                durationSeconds: chunk.expectedDurationSeconds,
                includeAudio: true,
                hasAudioTrack: true,
                colorInfo: .hlgBT2020Intermediate,
                sourceDescription: "HDR chunk \(chunk.sequenceIndex + 1) of \(chunkPlan.chunks.count)"
            )
        }

        let mergedPlan = FFmpegRenderPlan(
            clips: finalClips,
            transitionDurationSeconds: finalPlan.transitionDurationSeconds,
            outputURL: finalPlan.outputURL,
            renderSize: finalPlan.renderSize,
            frameRate: finalPlan.frameRate,
            audioLayout: finalPlan.audioLayout,
            bitrateMode: finalPlan.bitrateMode,
            container: finalPlan.container,
            videoCodec: finalPlan.videoCodec,
            dynamicRange: finalPlan.dynamicRange,
            hdrHEVCEncoderMode: finalPlan.hdrHEVCEncoderMode,
            renderIntent: .finalDelivery
        )

        return FFmpegHDRChunkExecutionPlan(
            chunkPlan: chunkPlan,
            chunkPlans: chunkPlans,
            finalPlan: mergedPlan
        )
    }
}

private extension ColorInfo {
    static let hlgBT2020Intermediate = ColorInfo(
        isHDR: true,
        colorPrimaries: "ITU_R_2020",
        transferFunction: "ITU_R_2100_HLG"
    )
}
