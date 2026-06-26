//
//  SearchableModelPicker.swift
//  Fluid
//
//  A searchable picker for selecting AI models.
//  Uses a popover with search field for better UX.
//

import SwiftUI

struct SearchableModelPicker: View {
    @Environment(\.theme) private var theme
    let models: [String]
    @Binding var selectedModel: String
    var onRefresh: (() async -> Void)?
    var isRefreshing: Bool = false
    var refreshEnabled: Bool = true
    var selectionEnabled: Bool = true
    let controlWidth: CGFloat
    let controlHeight: CGFloat?

    init(
        models: [String],
        selectedModel: Binding<String>,
        onRefresh: (() async -> Void)? = nil,
        isRefreshing: Bool = false,
        refreshEnabled: Bool = true,
        selectionEnabled: Bool = true,
        controlWidth: CGFloat = 180,
        controlHeight: CGFloat? = nil
    ) {
        self.models = models
        self._selectedModel = selectedModel
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.refreshEnabled = refreshEnabled
        self.selectionEnabled = selectionEnabled
        self.controlWidth = controlWidth
        self.controlHeight = controlHeight
    }

    @State private var searchText = ""
    @State private var isShowingPopover = false

    private var refreshButtonSize: CGFloat {
        self.controlHeight ?? 24
    }

    private var pickerControlWidth: CGFloat? {
        guard self.onRefresh != nil, self.controlHeight != nil else {
            return self.controlWidth
        }
        return max(self.controlWidth - self.refreshButtonSize - 8, 80)
    }

    private var filteredModels: [String] {
        if self.searchText.isEmpty {
            return self.models
        }
        return self.models.filter { $0.localizedCaseInsensitiveContains(self.searchText) }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Model button that opens popover
            Button(action: { self.isShowingPopover.toggle() }) {
                HStack(spacing: 6) {
                    Text(self.selectedModel.isEmpty ? "Select Model" : self.selectedModel)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(self.selectedModel.isEmpty ? .secondary : self.theme.palette.primaryText)
                    Spacer(minLength: 6)
                    FluidPickerDisclosureIcon(backgroundOpacity: 0.6)
                }
                .searchablePickerControlChrome(
                    width: self.pickerControlWidth,
                    height: self.controlHeight,
                    usesMaterial: true,
                    showsShadow: true
                )
            }
            .buttonStyle(.plain)
            .disabled(!self.selectionEnabled)
            .opacity(self.selectionEnabled ? 1 : 0.55)
            .popover(isPresented: self.$isShowingPopover, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    // Search field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search models...", text: self.$searchText)
                            .textFieldStyle(.plain)
                    }
                    .searchablePickerSearchFieldChrome()

                    Divider()

                    VStack(spacing: 0) {
                        if self.models.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tray")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("No models")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Click refresh to fetch from API")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(height: 100)
                            .frame(maxWidth: .infinity)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    if self.filteredModels.isEmpty {
                                        Text("No models match '\(self.searchText)'")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding()
                                            .frame(maxWidth: .infinity, alignment: .center)
                                    } else {
                                        ForEach(self.filteredModels.prefix(100), id: \.self) { model in
                                            Button(action: {
                                                self.selectedModel = model
                                                self.searchText = ""
                                                self.isShowingPopover = false
                                            }) {
                                                HStack {
                                                    Text(model)
                                                        .lineLimit(1)
                                                    Spacer()
                                                    if model == self.selectedModel {
                                                        Image(systemName: "checkmark")
                                                            .foregroundStyle(self.theme.palette.accent)
                                                    }
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .searchablePickerSelectedRowBackground(isSelected: model == self.selectedModel)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 250)

                            if self.filteredModels.count > 100 {
                                Divider()
                                Text("\(self.filteredModels.count - 100) more (use search)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(6)
                            }
                        }
                    }
                    .id(self.searchText.isEmpty)
                }
                .frame(width: 280)
            }

            // Refresh button
            if let onRefresh = onRefresh {
                if self.controlHeight == nil {
                    Button(action: {
                        Task { await onRefresh() }
                    }) {
                        if self.isRefreshing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(self.isRefreshing || !self.refreshEnabled)
                    .opacity(self.refreshEnabled ? 1 : 0.45)
                    .help("Refresh model list")
                } else {
                    Button(action: {
                        Task { await onRefresh() }
                    }) {
                        ZStack {
                            if self.isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .frame(width: self.refreshButtonSize, height: self.refreshButtonSize)
                    }
                    .fluidCompactButton(isReady: false)
                    .disabled(self.isRefreshing || !self.refreshEnabled)
                    .opacity(self.refreshEnabled ? 1 : 0.45)
                    .help("Refresh model list")
                }
            }
        }
    }
}

#Preview {
    SearchableModelPicker(
        models: ["gpt-4.1", "gpt-4o", "gpt-3.5-turbo", "claude-3-opus", "claude-3-sonnet"],
        selectedModel: .constant("gpt-4.1"),
        onRefresh: { try? await Task.sleep(nanoseconds: 1_000_000_000) },
        isRefreshing: false
    )
    .padding()
}
