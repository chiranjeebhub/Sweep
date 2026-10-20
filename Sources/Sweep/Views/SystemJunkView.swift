import AppKit
import SwiftUI
import SweepCore

struct SystemJunkView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: JunkModel
    @State private var confirming = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "System Junk",
                         subtitle: "Caches, logs and leftovers that are safe to remove. Apps rebuild what they need.") {
                if model.hasScanned {
                    Button("Rescan") { Task { await model.scan() } }.buttonStyle(LinkButtonStyle())
                }
            }
            Rectangle().fill(Theme.divider).frame(height: 1)

            if model.isScanning {
                StatusMessage(symbol: "", title: "Looking for junk…", showsProgress: true)
            } else if !model.hasScanned {
                StatusMessage(symbol: "trash", title: "Scan for system junk",
                              detail: "Find caches, logs and build files that are taking up space.")
                    .overlay(alignment: .bottom) {
                        Button("Scan") { Task { await model.scan() } }
                            .buttonStyle(PillButtonStyle())
                            .padding(.bottom, 140)
                    }
            } else if model.totalSize == 0 {
                StatusMessage(symbol: "checkmark.circle", title: "No junk found", detail: resultMessage)
            } else {
                HStack(spacing: 0) {
                    categoryList
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    itemList
                }
                footer
            }
        }
        .task { if !model.hasScanned && !model.isScanning { await model.scan() } }
        .alert("Move \(ByteFormat.string(model.selectedSize)) of junk to the Trash?", isPresented: $confirming) {
            Button("Clean") {
                Task {
                    let result = await model.clean()
                    resultMessage = "Freed \(ByteFormat.string(result.freedBytes))."
                        + (result.failures.isEmpty ? "" : " \(result.failures.count) items were in use and were skipped.")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore anything from the Trash until you empty it.")
        }
    }

    private var categoryList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.categories.filter { !$0.items.isEmpty }) { category in
                    let isFocused = model.focusedCategory == category.kind
                    HStack(spacing: 10) {
                        CheckBox(isOn: Binding(get: { model.isSelected(category) },
                                               set: { model.setSelected(category, $0) }),
                                 label: category.title)
                        Text(category.title).font(.system(size: 13.5))
                        Spacer()
                        Text(ByteFormat.string(category.size)).font(.system(size: 12.5)).foregroundStyle(Theme.mutedText)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isFocused ? Theme.selection : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.focusedCategory = category.kind }
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    @ViewBuilder private var itemList: some View {
        if let category = model.focused {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title).font(.system(size: 16, weight: .semibold))
                        Text(category.subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.faintText)
                    }
                    Spacer()
                    Toggle("Select all", isOn: Binding(get: { model.isSelected(category) },
                                                       set: { model.setSelected(category, $0) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                HStack(spacing: 0) {
                    Spacer().frame(width: 32)
                    ColumnLabel("Name")
                    Spacer()
                    ColumnLabel("Modified").frame(width: 140, alignment: .leading)
                    ColumnLabel("Size").frame(width: 90, alignment: .trailing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(category.items) { item in
                            HStack(spacing: 0) {
                                CheckBox(isOn: Binding(get: { model.isSelected(item) },
                                                       set: { model.setSelected(item, $0) }),
                                         label: item.name)
                                    .frame(width: 32, alignment: .leading)
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                    .resizable().frame(width: 22, height: 22)
                                    .padding(.trailing, 10)
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 12)
                                Text(RelativeDate.string(item.lastUsed))
                                    .font(.system(size: 12.5)).foregroundStyle(Theme.faintText)
                                    .frame(width: 140, alignment: .leading)
                                Text(ByteFormat.string(item.size))
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .font(.system(size: 13.5))
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .help(item.url.abbreviatedPath)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Spacer()
        }
    }

    private var footer: some View {
        FooterBar {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ByteFormat.string(model.selectedSize)) selected").font(.system(size: 15, weight: .semibold))
                Text(resultMessage ?? "Items move to the Trash first, so you can restore them")
                    .font(.system(size: 12)).foregroundStyle(Theme.faintText)
            }
            Spacer()
            Button(model.isCleaning ? "Cleaning…" : "Clean") { confirming = true }
                .buttonStyle(PillButtonStyle())
                .disabled(model.selectedSize == 0 || model.isCleaning)
        }
    }
}
