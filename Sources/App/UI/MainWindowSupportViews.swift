import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

enum MainWindowTheme {
    static let accentTeal = Color(red: 0.12, green: 0.56, blue: 0.58)
    static let accentNavy = Color(red: 0.15, green: 0.24, blue: 0.46)
    static let accentPeach = Color(red: 0.94, green: 0.63, blue: 0.43)
    static let accentAmber = Color(red: 0.74, green: 0.58, blue: 0.29)
    static let accentGreen = Color.green.opacity(0.8)
    static let accentRed = Color.red.opacity(0.8)
}

struct MainWindowSectionLabel: View {
    let title: String
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent)
                .frame(width: 8, height: 18)

            Text(title)
                .font(.headline)
                .foregroundStyle(accent)
        }
    }
}

struct MainWindowCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct MainWindowSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let displayValue: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 132, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(displayValue)
                .frame(width: 64, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

struct MainWindowStatusLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(title):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MainWindowCurrentJobCard: View {
    @ObservedObject var viewModel: MainWindowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Current Job")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(viewModel.currentRenderDrawerDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.currentRenderSourceSummary)
                .font(.callout)

            MainWindowCaption(text: "Output: \(viewModel.currentRenderOutputNamePreview)")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(queueCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(MainWindowTheme.accentTeal.opacity(0.18), lineWidth: 1)
        )
    }

    private var queueCardBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
        #else
        Color.secondary.opacity(0.08)
        #endif
    }
}

struct MainWindowQueueJobTile: View {
    let label: String
    let state: MainWindowViewModel.QueuedRenderJobState
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(state.displayLabel.lowercased())
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
        }
        .frame(width: 76, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(queueStateFill(state))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? queueStateColor(state) : queueStateColor(state).opacity(0.18),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func queueStateFill(_ state: MainWindowViewModel.QueuedRenderJobState) -> Color {
        switch state {
        case .queued:
            return queueCardBackground
        case .running:
            return MainWindowTheme.accentAmber.opacity(0.18)
        case .paused:
            return MainWindowTheme.accentAmber.opacity(0.12)
        case .completed:
            return MainWindowTheme.accentGreen.opacity(0.14)
        case .failed:
            return MainWindowTheme.accentRed.opacity(0.14)
        }
    }

    private var queueCardBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
        #else
        Color.secondary.opacity(0.08)
        #endif
    }

    private func queueStateColor(_ state: MainWindowViewModel.QueuedRenderJobState) -> Color {
        switch state {
        case .queued:
            return MainWindowTheme.accentNavy
        case .running:
            return MainWindowTheme.accentAmber
        case .paused:
            return MainWindowTheme.accentAmber
        case .completed:
            return MainWindowTheme.accentGreen
        case .failed:
            return MainWindowTheme.accentRed
        }
    }
}

struct MainWindowQueueJobDetailCard: View {
    let job: MainWindowViewModel.QueuedRenderJob
    let removeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(job.state == .running ? "Current Job" : "Selected Job")
                    .font(.subheadline.weight(.semibold))

                Text(job.state.displayLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(queueStateColor(job.state), in: Capsule())

                Spacer(minLength: 8)

                if job.state != .running {
                    Button("Remove", action: removeAction)
                        .buttonStyle(.borderless)
                }
            }

            Text(job.sourceSummary)
                .font(.callout.weight(.semibold))

            MainWindowCaption(text: "Output: \(job.outputNamePreview)")

            if !job.lastResultMessage.isEmpty {
                MainWindowCaption(text: job.lastResultMessage)
            }

            if let resultSummary = job.resultSummary {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        MainWindowCaption(text: resultSummary.elapsedLabel)
                        MainWindowCaption(text: resultSummary.metricsLine)
                        MainWindowCaption(text: "File: \(resultSummary.outputFilename)")
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        MainWindowCaption(text: resultSummary.elapsedLabel)
                        MainWindowCaption(text: resultSummary.metricsLine)
                        MainWindowCaption(text: "File: \(resultSummary.outputFilename)")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(queueCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(queueStateColor(job.state).opacity(0.18), lineWidth: 1)
        )
    }

    private var queueCardBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
        #else
        Color.secondary.opacity(0.08)
        #endif
    }

    private func queueStateColor(_ state: MainWindowViewModel.QueuedRenderJobState) -> Color {
        switch state {
        case .queued:
            return MainWindowTheme.accentNavy
        case .running:
            return MainWindowTheme.accentTeal
        case .paused:
            return MainWindowTheme.accentAmber
        case .completed:
            return MainWindowTheme.accentGreen
        case .failed:
            return MainWindowTheme.accentRed
        }
    }
}
