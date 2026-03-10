import Foundation

struct FFmpegProgressiveBatchPlan: Equatable, Sendable {
    let sequenceIndex: Int
    let sourceClipIndices: [Int]
    let plan: FFmpegRenderPlan
}

struct FFmpegHDRProgressiveExecutionPlan: Equatable, Sendable {
    let activationChunkPlan: FFmpegHDRChunkPlan
    let presentationPlans: [FFmpegRenderPlan]
    let slices: [FFmpegAssemblySlice]
    let batchPlans: [FFmpegProgressiveBatchPlan]
    let lastBatchIndexBySourceClip: [Int: Int]
    let concatListURL: URL
    let concatOutputURL: URL
}

struct FFmpegHDRProgressivePipelineBuilder {
    private let epsilon = 0.000_1

    let activationPlanner: FFmpegHDRChunkPlanner
    let maxUniqueSourceClipsPerBatch: Int
    let maxBatchDurationSeconds: Double

    init(
        activationPlanner: FFmpegHDRChunkPlanner = FFmpegHDRChunkPlanner(),
        maxUniqueSourceClipsPerBatch: Int = 12,
        maxBatchDurationSeconds: Double = 90
    ) {
        self.activationPlanner = activationPlanner
        self.maxUniqueSourceClipsPerBatch = max(maxUniqueSourceClipsPerBatch, 1)
        self.maxBatchDurationSeconds = max(maxBatchDurationSeconds, 0.01)
    }

    func makeExecutionPlan(
        for finalPlan: FFmpegRenderPlan,
        presentationOutputURL: (Int) -> URL,
        batchOutputURL: (Int) -> URL,
        concatListURL: () -> URL,
        concatOutputURL: () -> URL
    ) -> FFmpegHDRProgressiveExecutionPlan? {
        guard finalPlan.dynamicRange == .hdr,
              finalPlan.videoCodec == .hevc,
              finalPlan.renderIntent == .finalDelivery else {
            return nil
        }

        let activationChunkPlan = activationPlanner.plan(for: finalPlan)
        guard activationChunkPlan.requiresChunking else {
            return nil
        }

        let presentationPlans = finalPlan.clips.enumerated().map { index, clip in
            FFmpegRenderPlan(
                clips: [clip],
                transitionDurationSeconds: 0,
                endFadeToBlackDurationSeconds: 0,
                outputURL: presentationOutputURL(index),
                renderSize: finalPlan.renderSize,
                frameRate: finalPlan.frameRate,
                audioLayout: finalPlan.audioLayout,
                bitrateMode: finalPlan.bitrateMode,
                container: .mov,
                videoCodec: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: finalPlan.hdrHEVCEncoderMode,
                embeddedMetadata: nil,
                chapters: [],
                chapterMetadataURL: nil,
                renderIntent: .presentationIntermediate
            )
        }

        let presentationClips = finalPlan.clips.enumerated().map { index, clip in
            FFmpegRenderClip(
                url: presentationPlans[index].outputURL,
                durationSeconds: clip.durationSeconds,
                includeAudio: true,
                hasAudioTrack: true,
                colorInfo: .hlgBT2020Intermediate,
                sourceDescription: clip.sourceDescription
            )
        }

        let slices = makeAssemblySlices(
            clips: presentationClips,
            transitionDurationSeconds: finalPlan.transitionDurationSeconds
        )
        guard !slices.isEmpty else {
            return nil
        }

        let batchPlans = makeBatchPlans(
            slices: slices,
            presentationClips: presentationClips,
            finalPlan: finalPlan,
            batchOutputURL: batchOutputURL
        )
        guard !batchPlans.isEmpty else {
            return nil
        }

        var lastBatchIndexBySourceClip: [Int: Int] = [:]
        for batch in batchPlans {
            for sourceClipIndex in batch.sourceClipIndices {
                lastBatchIndexBySourceClip[sourceClipIndex] = batch.sequenceIndex
            }
        }

        return FFmpegHDRProgressiveExecutionPlan(
            activationChunkPlan: activationChunkPlan,
            presentationPlans: presentationPlans,
            slices: slices,
            batchPlans: batchPlans,
            lastBatchIndexBySourceClip: lastBatchIndexBySourceClip,
            concatListURL: concatListURL(),
            concatOutputURL: concatOutputURL()
        )
    }

    func requiresProgressiveExecution(for finalPlan: FFmpegRenderPlan) -> Bool {
        guard finalPlan.dynamicRange == .hdr,
              finalPlan.videoCodec == .hevc,
              finalPlan.renderIntent == .finalDelivery else {
            return false
        }
        return activationPlanner.plan(for: finalPlan).requiresChunking
    }

    private func makeAssemblySlices(
        clips: [FFmpegRenderClip],
        transitionDurationSeconds: Double
    ) -> [FFmpegAssemblySlice] {
        guard !clips.isEmpty else {
            return []
        }

        let transition = max(transitionDurationSeconds, 0)
        var slices: [FFmpegAssemblySlice] = []
        var nextSequenceIndex = 0

        for index in clips.indices {
            let clip = clips[index]
            let incomingTransition = index == 0 ? 0 : transition
            let outgoingTransition = index == clips.count - 1 ? 0 : transition
            let bodyStart = min(max(incomingTransition, 0), clip.durationSeconds)
            let bodyDuration = max(clip.durationSeconds - incomingTransition - outgoingTransition, 0)
            if bodyDuration > epsilon {
                slices.append(
                    FFmpegAssemblySlice(
                        sequenceIndex: nextSequenceIndex,
                        kind: .body,
                        segments: [
                            FFmpegAssemblySegment(
                                clipIndex: index,
                                startTimeSeconds: bodyStart,
                                durationSeconds: bodyDuration
                            )
                        ],
                        outputDurationSeconds: bodyDuration
                    )
                )
                nextSequenceIndex += 1
            }

            if index < clips.count - 1, transition > epsilon {
                let nextClip = clips[index + 1]
                let leftStart = max(clip.durationSeconds - transition, 0)
                let leftDuration = min(transition, max(clip.durationSeconds - leftStart, 0))
                let rightDuration = min(transition, nextClip.durationSeconds)
                let bridgeDuration = min(leftDuration, rightDuration)
                if bridgeDuration > epsilon {
                    slices.append(
                        FFmpegAssemblySlice(
                            sequenceIndex: nextSequenceIndex,
                            kind: .bridge,
                            segments: [
                                FFmpegAssemblySegment(
                                    clipIndex: index,
                                    startTimeSeconds: leftStart,
                                    durationSeconds: bridgeDuration
                                ),
                                FFmpegAssemblySegment(
                                    clipIndex: index + 1,
                                    startTimeSeconds: 0,
                                    durationSeconds: bridgeDuration
                                )
                            ],
                            outputDurationSeconds: bridgeDuration
                        )
                    )
                    nextSequenceIndex += 1
                }
            }
        }

        return slices
    }

    private func makeBatchPlans(
        slices: [FFmpegAssemblySlice],
        presentationClips: [FFmpegRenderClip],
        finalPlan: FFmpegRenderPlan,
        batchOutputURL: (Int) -> URL
    ) -> [FFmpegProgressiveBatchPlan] {
        guard !slices.isEmpty else {
            return []
        }

        var groupedSlices: [[FFmpegAssemblySlice]] = []
        var workingSlices: [FFmpegAssemblySlice] = []
        var workingClipIndices: Set<Int> = []
        var workingDuration = 0.0

        func flushWorkingSlices() {
            guard !workingSlices.isEmpty else {
                return
            }
            groupedSlices.append(workingSlices)
            workingSlices = []
            workingClipIndices.removeAll(keepingCapacity: false)
            workingDuration = 0
        }

        for slice in slices {
            let sliceClipIndices = Set(slice.sourceClipIndices)
            let proposedClipIndices = workingClipIndices.union(sliceClipIndices)
            let proposedDuration = workingDuration + slice.outputDurationSeconds
            let exceedsBatchBounds = !workingSlices.isEmpty && (
                proposedClipIndices.count > maxUniqueSourceClipsPerBatch ||
                proposedDuration > maxBatchDurationSeconds
            )

            if exceedsBatchBounds {
                flushWorkingSlices()
            }

            workingSlices.append(slice)
            workingClipIndices.formUnion(sliceClipIndices)
            workingDuration += slice.outputDurationSeconds
        }
        flushWorkingSlices()

        return groupedSlices.enumerated().map { batchIndex, batchSlices in
            let orderedOriginalClipIndices = orderedSourceClipIndices(for: batchSlices)
            let localClipIndexByOriginal = Dictionary(
                uniqueKeysWithValues: orderedOriginalClipIndices.enumerated().map { localIndex, originalIndex in
                    (originalIndex, localIndex)
                }
            )
            let localClips = orderedOriginalClipIndices.map { presentationClips[$0] }
            let localSlices = batchSlices.map { slice in
                FFmpegAssemblySlice(
                    sequenceIndex: slice.sequenceIndex,
                    kind: slice.kind,
                    segments: slice.segments.map { segment in
                        FFmpegAssemblySegment(
                            clipIndex: localClipIndexByOriginal[segment.clipIndex] ?? 0,
                            startTimeSeconds: segment.startTimeSeconds,
                            durationSeconds: segment.durationSeconds
                        )
                    },
                    outputDurationSeconds: slice.outputDurationSeconds
                )
            }

            return FFmpegProgressiveBatchPlan(
                sequenceIndex: batchIndex,
                sourceClipIndices: orderedOriginalClipIndices,
                plan: FFmpegRenderPlan(
                    clips: localClips,
                    assemblySlices: localSlices,
                    transitionDurationSeconds: 0,
                    endFadeToBlackDurationSeconds: batchIndex == groupedSlices.count - 1
                        ? finalPlan.endFadeToBlackDurationSeconds
                        : 0,
                    outputURL: batchOutputURL(batchIndex),
                    renderSize: finalPlan.renderSize,
                    frameRate: finalPlan.frameRate,
                    audioLayout: finalPlan.audioLayout,
                    bitrateMode: finalPlan.bitrateMode,
                    container: .mov,
                    videoCodec: .hevc,
                    dynamicRange: .hdr,
                    hdrHEVCEncoderMode: finalPlan.hdrHEVCEncoderMode,
                    embeddedMetadata: nil,
                    chapters: [],
                    chapterMetadataURL: nil,
                    renderIntent: .finalBatch
                )
            )
        }
    }

    private func orderedSourceClipIndices(for slices: [FFmpegAssemblySlice]) -> [Int] {
        var orderedIndices: [Int] = []
        var seen: Set<Int> = []
        for slice in slices {
            for sourceClipIndex in slice.sourceClipIndices where seen.insert(sourceClipIndex).inserted {
                orderedIndices.append(sourceClipIndex)
            }
        }
        return orderedIndices
    }
}

extension ColorInfo {
    static let hlgBT2020Intermediate = ColorInfo(
        isHDR: true,
        colorPrimaries: "ITU_R_2020",
        transferFunction: "ITU_R_2100_HLG"
    )
}
