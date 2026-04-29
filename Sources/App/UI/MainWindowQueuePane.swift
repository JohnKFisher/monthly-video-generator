import SwiftUI

struct MainWindowQueuePane: View {
    @ObservedObject var viewModel: MainWindowViewModel

    @State private var selectedQueuedJobID: MainWindowViewModel.QueuedRenderJob.ID?

    private let rowSpacing: CGFloat = 8

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: rowSpacing) {
                queueActions

                if viewModel.queuedRenderJobs.isEmpty {
                    MainWindowCurrentJobCard(viewModel: viewModel)
                } else {
                    queueFlightStrip

                    if let selectedQueuedJob {
                        MainWindowQueueJobDetailCard(job: selectedQueuedJob) {
                            if selectedQueuedJobID == selectedQueuedJob.id {
                                selectedQueuedJobID = nil
                            }
                            viewModel.removeQueuedRenderJob(id: selectedQueuedJob.id)
                        }
                    }
                }

                MainWindowCaption(text: viewModel.queueStatusDescription)

                if viewModel.showsSelectedYearQueueAction {
                    MainWindowCaption(text: viewModel.selectedYearQueueDescription)
                }

                if viewModel.isPreparingYearQueue {
                    HStack(spacing: 8) {
                        ProgressView()
                        MainWindowCaption(text: "Scanning \(viewModel.yearQueueLabelYear) for non-empty months…")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            MainWindowSectionLabel(title: "Job Drawer", accent: MainWindowTheme.accentNavy)
        }
    }

    private var selectedQueuedJob: MainWindowViewModel.QueuedRenderJob? {
        if
            let selectedQueuedJobID,
            let selectedJob = viewModel.queuedRenderJobs.first(where: { $0.id == selectedQueuedJobID })
        {
            return selectedJob
        }

        guard let preferredID = viewModel.preferredQueueDetailJobID else {
            return nil
        }
        return viewModel.queuedRenderJobs.first(where: { $0.id == preferredID })
    }

    private var queueFlightStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.queuedRenderJobs) { job in
                        Button {
                            selectedQueuedJobID = job.id
                        } label: {
                            MainWindowQueueJobTile(
                                label: viewModel.queueTileLabel(for: job),
                                state: job.state,
                                isSelected: selectedQueuedJob?.id == job.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(job.state.displayLabel): \(job.sourceSummary)")
                    }
                }
                .padding(.vertical, 2)
            }

            ProgressView(value: viewModel.queueProgress)
                .tint(MainWindowTheme.accentAmber)

            MainWindowCaption(text: "Queue: \(viewModel.queueProgressLabel) complete")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(queueCardBackground)
        )
    }

    private var queueActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button(viewModel.addCurrentSettingsToQueueLabel) {
                    viewModel.addCurrentSettingsToQueue()
                }
                .disabled(!viewModel.canAddCurrentSettingsToQueue)

                if viewModel.showsSelectedYearQueueAction {
                    Button(viewModel.isPreparingYearQueue ? "Scanning Year…" : "Add Full Year") {
                        viewModel.addSelectedYearToQueue()
                    }
                    .disabled(!viewModel.canAddSelectedYearToQueue)
                }

                Spacer(minLength: 0)

                if viewModel.isQueueRunning {
                    Button(viewModel.isQueuePauseRequested ? "Pausing after this item…" : "Pause After Current Item") {
                        viewModel.pauseQueueAfterCurrentItem()
                    }
                    .disabled(!viewModel.canPauseQueueAfterCurrentItem)
                }

                Button("Start Queue") {
                    viewModel.startQueue()
                }
                .disabled(!viewModel.canStartQueue)

                Button("Clear Queue") {
                    viewModel.clearQueuedRenderJobs()
                }
                .disabled(!viewModel.canClearQueue)
            }

            VStack(alignment: .leading, spacing: rowSpacing) {
                Button(viewModel.addCurrentSettingsToQueueLabel) {
                    viewModel.addCurrentSettingsToQueue()
                }
                .disabled(!viewModel.canAddCurrentSettingsToQueue)

                if viewModel.showsSelectedYearQueueAction {
                    Button(viewModel.isPreparingYearQueue ? "Scanning Year…" : "Add Full Year") {
                        viewModel.addSelectedYearToQueue()
                    }
                    .disabled(!viewModel.canAddSelectedYearToQueue)
                }

                HStack(spacing: 10) {
                    if viewModel.isQueueRunning {
                        Button(viewModel.isQueuePauseRequested ? "Pausing after this item…" : "Pause After Current Item") {
                            viewModel.pauseQueueAfterCurrentItem()
                        }
                        .disabled(!viewModel.canPauseQueueAfterCurrentItem)
                    }

                    Button("Start Queue") {
                        viewModel.startQueue()
                    }
                    .disabled(!viewModel.canStartQueue)

                    Button("Clear Queue") {
                        viewModel.clearQueuedRenderJobs()
                    }
                    .disabled(!viewModel.canClearQueue)
                }
            }
        }
    }

    private var queueCardBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
        #else
        Color.secondary.opacity(0.08)
        #endif
    }
}
