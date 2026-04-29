import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MainWindowStatusPane: View {
    @ObservedObject var viewModel: MainWindowViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Version \(AppMetadata.versionBuildValue)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if viewModel.canRevealLastRenderedOutput {
                        Button("Reveal Last Export") {
                            viewModel.revealLastRenderedOutput()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    MainWindowProgressRow(
                        title: "Current item",
                        value: viewModel.currentItemProgress,
                        label: viewModel.currentItemProgressLabel
                    )

                    if viewModel.showsQueueProgress {
                        MainWindowProgressRow(
                            title: "Queue",
                            value: viewModel.queueProgress,
                            label: viewModel.queueProgressLabel
                        )
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 140), alignment: .leading),
                        GridItem(.flexible(minimum: 140), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    MainWindowStatusMetric(title: "Phase", value: viewModel.statusPhaseLabel)
                    MainWindowStatusMetric(title: "Progress", value: viewModel.statusProgressLabel)
                    MainWindowStatusMetric(title: "Elapsed", value: viewModel.statusElapsedLabel)
                    MainWindowStatusMetric(title: "Queue", value: viewModel.statusQueueLabel)
                    if !viewModel.currentArtifactSizeLabel.isEmpty {
                        MainWindowStatusMetric(title: "Artifact Size", value: viewModel.currentArtifactSizeLabel)
                    }
                    if !viewModel.currentArtifactLabel.isEmpty {
                        MainWindowStatusMetric(title: "Artifact", value: viewModel.currentArtifactLabel)
                    }
                }

                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !viewModel.statusOutputLabel.isEmpty {
                    MainWindowStatusLine(title: "Target", value: viewModel.statusOutputLabel)
                }

                MainWindowLiveSnapshotView(viewModel: viewModel)

                if !viewModel.lastOutputPath.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        MainWindowStatusLine(title: "Output", value: viewModel.lastOutputPath)

                        Button("Reveal Folder") {
                            viewModel.openRenderedOutputFolder()
                        }
                    }
                }

                if !viewModel.lastDiagnosticsPath.isEmpty {
                    MainWindowStatusLine(title: "Diagnostics", value: viewModel.lastDiagnosticsPath)
                }

                if !viewModel.lastBackendSummary.isEmpty {
                    MainWindowStatusLine(title: "Backend", value: viewModel.lastBackendSummary)
                }

                Divider()

                HStack {
                    Spacer(minLength: 0)

                    Button("Cancel") {
                        viewModel.cancelRender()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isRendering)

                    Button("Generate Video") {
                        viewModel.startRender()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MainWindowTheme.accentPeach)
                    .disabled(!viewModel.canStartRender)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            MainWindowSectionLabel(title: "Status", accent: MainWindowTheme.accentTeal)
        }
    }
}

private struct MainWindowStatusMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MainWindowProgressRow: View {
    let title: String
    let value: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: min(max(value, 0), 1))
        }
    }
}

private struct MainWindowLiveSnapshotView: View {
    @ObservedObject var viewModel: MainWindowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Live Snapshot", systemImage: "photo.on.rectangle.angled")
                    .font(.caption.weight(.semibold))
                Spacer()
                if !viewModel.liveSnapshotCapturedLabel.isEmpty {
                    Text(viewModel.liveSnapshotCapturedLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5))

                if let snapshotURL = viewModel.liveSnapshotImageURL,
                   let image = NSImage(contentsOf: snapshotURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(viewModel.liveSnapshotStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                    .padding(12)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            )

            Text(viewModel.liveSnapshotStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !viewModel.currentArtifactPath.isEmpty {
                MainWindowStatusLine(title: "Snapshot Source", value: viewModel.currentArtifactPath)
            }
        }
    }
}
