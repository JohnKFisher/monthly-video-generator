import SwiftUI

struct MainWindowQueuePane: View {
    @ObservedObject var viewModel: MainWindowViewModel
    @Binding var isRenderQueueExpanded: Bool

    private let rowSpacing: CGFloat = 8

    var body: some View {
        GroupBox {
            DisclosureGroup("Render Queue", isExpanded: $isRenderQueueExpanded) {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    queueActions

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

                    if viewModel.queuedRenderJobs.isEmpty {
                        MainWindowCaption(text: "No queued renders yet.")
                    } else {
                        VStack(alignment: .leading, spacing: rowSpacing) {
                            ForEach(viewModel.queuedRenderJobs) { job in
                                MainWindowQueueJobRow(job: job) {
                                    viewModel.removeQueuedRenderJob(id: job.id)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            MainWindowSectionLabel(title: "Queue", accent: MainWindowTheme.accentNavy)
        }
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
}
