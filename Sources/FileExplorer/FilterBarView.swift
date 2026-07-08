import SwiftUI
import FileExplorerCore

struct FilterBarView: View {
    @Bindable var pane: PaneState
    var settings: SettingsModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TypePreset.allCases, id: \.self) { preset in
                Toggle(preset.rawValue, isOn: Binding(
                    get: { pane.filter.preset == preset },
                    set: { pane.filter.preset = $0 ? preset : nil }))
                    .toggleStyle(.button)
                    .controlSize(.small)
            }

            Divider().frame(height: 14)

            Menu {
                Button("Any Time") {
                    pane.filter.datePreset = nil
                    pane.filter.customDateRange = nil
                }
                Divider()
                ForEach(DatePreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) {
                        pane.filter.customDateRange = nil
                        pane.filter.datePreset = preset
                    }
                }
                Divider()
                Button("Custom Range…") {
                    pane.filter.datePreset = nil
                    if pane.filter.customDateRange == nil {
                        let now = Date()
                        pane.filter.customDateRange =
                            now.addingTimeInterval(-86_400 * 7)...now
                    }
                    pane.showsCustomDatePopover = true
                }
            } label: {
                Label(pane.filter.customDateRange != nil ? "Custom"
                      : pane.filter.datePreset?.rawValue ?? "Date",
                      systemImage: "calendar")
            }
            .controlSize(.small)
            .fixedSize()
            .popover(isPresented: Binding(
                get: { pane.showsCustomDatePopover },
                set: { pane.showsCustomDatePopover = $0 })) {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("From", selection: Binding(
                        get: { pane.filter.customDateRange?.lowerBound ?? Date() },
                        set: { newStart in
                            let end = pane.filter.customDateRange?.upperBound ?? Date()
                            pane.filter.customDateRange = min(newStart, end)...max(newStart, end)
                        }), displayedComponents: .date)
                    DatePicker("To", selection: Binding(
                        get: { pane.filter.customDateRange?.upperBound ?? Date() },
                        set: { newEnd in
                            let start = pane.filter.customDateRange?.lowerBound ?? Date()
                            pane.filter.customDateRange = min(start, newEnd)...max(start, newEnd)
                        }), displayedComponents: .date)
                    Button("Clear") {
                        pane.filter.customDateRange = nil
                        pane.showsCustomDatePopover = false
                    }
                }
                .padding(12)
                .frame(width: 240)
            }

            Menu {
                Button("Any Size") {
                    pane.filter.sizePreset = nil
                    pane.filter.customSizeRange = nil
                }
                Divider()
                ForEach(SizePreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) {
                        pane.filter.customSizeRange = nil
                        pane.filter.sizePreset = preset
                    }
                }
                Divider()
                Button("Custom Range…") {
                    pane.filter.sizePreset = nil
                    if pane.filter.customSizeRange == nil {
                        pane.filter.customSizeRange = Int64(0)...Int64(100 * 1_048_576)
                    }
                    pane.showsCustomSizePopover = true
                }
            } label: {
                Label(pane.filter.customSizeRange != nil ? "Custom"
                      : pane.filter.sizePreset?.rawValue ?? "Size",
                      systemImage: "scalemass")
            }
            .controlSize(.small)
            .fixedSize()
            .popover(isPresented: Binding(
                get: { pane.showsCustomSizePopover },
                set: { pane.showsCustomSizePopover = $0 })) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Min MB", text: Binding(
                        get: {
                            guard let range = pane.filter.customSizeRange else { return "" }
                            return range.lowerBound == 0 ? "" : String(range.lowerBound / 1_048_576)
                        },
                        set: { text in
                            let minBytes = FilterState.megabytesFieldToBytes(text)
                            let maxBytes = pane.filter.customSizeRange?.upperBound ?? Int64.max
                            pane.filter.customSizeRange = min(minBytes, maxBytes)...max(minBytes, maxBytes)
                        }))
                        .textFieldStyle(.roundedBorder)
                    TextField("Max MB", text: Binding(
                        get: {
                            guard let range = pane.filter.customSizeRange,
                                  range.upperBound != Int64.max else { return "" }
                            return String(range.upperBound / 1_048_576)
                        },
                        set: { text in
                            let maxBytes = text.trimmingCharacters(in: .whitespaces).isEmpty ? Int64.max
                                : FilterState.megabytesFieldToBytes(text)
                            let minBytes = pane.filter.customSizeRange?.lowerBound ?? 0
                            pane.filter.customSizeRange = min(minBytes, maxBytes)...max(minBytes, maxBytes)
                        }))
                        .textFieldStyle(.roundedBorder)
                    Button("Clear") {
                        pane.filter.customSizeRange = nil
                        pane.showsCustomSizePopover = false
                    }
                }
                .padding(12)
                .frame(width: 160)
            }

            Menu {
                Button("Any Tags") { pane.filter.tags = nil }
                Divider()
                ForEach(Array(Set(pane.entries.flatMap(\.tags))).sorted(),
                        id: \.self) { tag in
                    Toggle(tag, isOn: Binding(
                        get: { pane.filter.tags?.contains(tag) == true },
                        set: { isOn in
                            var tags = pane.filter.tags ?? []
                            if isOn { tags.insert(tag) } else { tags.remove(tag) }
                            pane.filter.tags = tags.isEmpty ? nil : tags
                        }))
                }
            } label: {
                Label(pane.filter.tags.map { "\($0.count) Tag\($0.count == 1 ? "" : "s")" }
                          ?? "Tags",
                      systemImage: "tag")
            }
            .controlSize(.small)
            .fixedSize()

            TextField("ext, ext…", text: $pane.filterExtensionsText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 120)

            Spacer()

            if pane.filter.isActive {
                Button("Save Preset…") {
                    pane.savePresetNameDraft = ""
                    pane.showsSavePresetPopover = true
                }
                .controlSize(.small)
                .popover(isPresented: Binding(
                    get: { pane.showsSavePresetPopover },
                    set: { pane.showsSavePresetPopover = $0 })) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Preset name", text: Binding(
                            get: { pane.savePresetNameDraft },
                            set: { pane.savePresetNameDraft = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Button("Save") {
                            settings.savePreset(name: pane.savePresetNameDraft,
                                                filter: pane.filter)
                            pane.showsSavePresetPopover = false
                        }
                        .disabled(pane.savePresetNameDraft
                            .trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(12)
                }
                Button("Clear") { pane.clearFilters() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}
