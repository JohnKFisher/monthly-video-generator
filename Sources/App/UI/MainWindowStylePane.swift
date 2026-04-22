import SwiftUI

struct MainWindowStylePane: View {
    @ObservedObject var viewModel: MainWindowViewModel

    private let rowSpacing: CGFloat = 8

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: rowSpacing) {
                Toggle("Opening title card", isOn: $viewModel.includeOpeningTitle)

                if viewModel.includeOpeningTitle {
                    TextField("Title text", text: $viewModel.openingTitleText)
                    MainWindowCaption(text: "Defaults to the selected month and year until you type a custom title.")

                    TextField("Small caption", text: $viewModel.openingTitleCaptionText)
                    MainWindowCaption(text: "Leave blank to hide the smaller caption.")

                    MainWindowSliderRow(
                        title: "Title card duration",
                        value: $viewModel.titleDurationSeconds,
                        range: 1...10,
                        step: 0.25,
                        displayValue: String(format: "%.2fs", viewModel.titleDurationSeconds)
                    )
                }

                MainWindowSliderRow(
                    title: "Crossfade",
                    value: $viewModel.crossfadeDurationSeconds,
                    range: 0...2,
                    step: 0.05,
                    displayValue: String(format: "%.2fs", viewModel.crossfadeDurationSeconds)
                )

                MainWindowSliderRow(
                    title: "Still image duration",
                    value: $viewModel.stillImageDurationSeconds,
                    range: 1...10,
                    step: 0.25,
                    displayValue: String(format: "%.2fs", viewModel.stillImageDurationSeconds)
                )

                Toggle("Show capture date", isOn: $viewModel.showCaptureDateOverlay)
                MainWindowCaption(text: "Displays each photo or video's capture date in the bottom-right corner using your current local timezone.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            MainWindowSectionLabel(title: "Style", accent: MainWindowTheme.accentPeach)
        }
    }
}
