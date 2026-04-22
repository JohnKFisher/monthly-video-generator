import Foundation

package struct FinalHEVCTuningOverride: Equatable, Sendable {
    package let preset: String
    package let crf: Int

    package init(preset: String, crf: Int) {
        self.preset = preset.trimmingCharacters(in: .whitespacesAndNewlines)
        self.crf = crf
    }
}

package struct RenderExecutionOptions: Equatable, Sendable {
    package static let `default` = RenderExecutionOptions()

    package let finalHEVCTuningOverride: FinalHEVCTuningOverride?

    package init(finalHEVCTuningOverride: FinalHEVCTuningOverride? = nil) {
        self.finalHEVCTuningOverride = finalHEVCTuningOverride
    }
}
