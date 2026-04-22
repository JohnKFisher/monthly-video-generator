import SwiftUI

struct MainWindowInputPane: View {
    @ObservedObject var viewModel: MainWindowViewModel

    private let rowSpacing: CGFloat = 8

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: rowSpacing) {
                if viewModel.sourceMode == .folder {
                    HStack(spacing: 10) {
                        Button("Choose Folder…") {
                            viewModel.chooseInputFolder()
                        }
                        .disabled(!viewModel.canChooseInputFolder)

                        Toggle("Recursive", isOn: $viewModel.recursiveScan)
                    }

                    Text(viewModel.selectedFolderURL?.path ?? "No folder selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else {
                    Picker("Photos Filter", selection: $viewModel.selectedPhotosFilterMode) {
                        ForEach(MainWindowViewModel.PhotosFilterMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if viewModel.selectedPhotosFilterMode == .monthYear {
                        HStack(spacing: 10) {
                            Picker("Month", selection: $viewModel.selectedMonth) {
                                ForEach(viewModel.months, id: \.self) { month in
                                    Text(viewModel.monthLabel(for: month)).tag(month)
                                }
                            }

                            Picker("Year", selection: $viewModel.selectedYear) {
                                ForEach(viewModel.years, id: \.self) { year in
                                    Text(String(year)).tag(year)
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            Picker("Album", selection: $viewModel.selectedPhotoAlbumID) {
                                if viewModel.photoAlbums.isEmpty {
                                    Text("No Albums Available").tag("")
                                } else {
                                    ForEach(viewModel.photoAlbums) { album in
                                        Text(album.displayLabel).tag(album.localIdentifier)
                                    }
                                }
                            }
                            .disabled(viewModel.isLoadingPhotoAlbums || !viewModel.hasPhotoAlbums)

                            Button("Refresh") {
                                viewModel.refreshPhotoAlbums()
                            }
                            .disabled(viewModel.isLoadingPhotoAlbums)
                        }

                        if viewModel.isLoadingPhotoAlbums {
                            HStack(spacing: 8) {
                                ProgressView()
                                MainWindowCaption(text: "Loading albums…")
                            }
                        } else if !viewModel.photoAlbumsStatusMessage.isEmpty {
                            MainWindowCaption(text: viewModel.photoAlbumsStatusMessage)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            MainWindowSectionLabel(title: "Input", accent: MainWindowTheme.accentTeal)
        }
    }
}
