import SwiftUI

struct MainWindowWarningsPane: View {
    @ObservedObject var viewModel: MainWindowViewModel
    @Binding var isExpanded: Bool

    var body: some View {
        if !viewModel.warnings.isEmpty {
            GroupBox {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } label: {
                    MainWindowSectionLabel(title: "Notes & Warnings", accent: MainWindowTheme.accentAmber)
                }
            }
        }
    }
}
