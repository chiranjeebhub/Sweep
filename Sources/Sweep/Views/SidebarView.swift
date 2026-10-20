import SwiftUI
import SweepCore

struct SidebarView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var optimization: OptimizationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic-light buttons, measured from the window's top edge.
            Spacer().frame(height: 42)

            HStack(spacing: 10) {
                // The app icon from Resources/AppIcon.icns; its artwork has a transparent margin, hence the larger frame.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)
                    .padding(-3)
                    .accessibilityHidden(true)
                Text("Sweep").font(.system(size: 16, weight: .bold))
            }
            // Lines the icon up with the left edge of the selected row below it, and keeps the
            // same gap above the logo (to the window buttons) as below it (to Smart Scan).
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Module.sections.indices, id: \.self) { index in
                    let section = Module.sections[index]
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = section.title {
                            Text(title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.faintText)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                        }
                        ForEach(section.modules) { module in
                            row(module)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            Spacer(minLength: 12)

            storageCard
                .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Panel and divider both run up under the title bar to the window's top edge.
        .background {
            HStack(spacing: 0) {
                Theme.panel
                Theme.border.frame(width: 1)
            }
            .ignoresSafeArea()
        }
    }

    private func row(_ module: Module) -> some View {
        let isActive = app.selection == module
        return Button {
            app.selection = module
        } label: {
            HStack(spacing: 10) {
                Image(systemName: module.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(module.title)
                    .font(.system(size: 13.5, weight: isActive ? .semibold : .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .foregroundStyle(isActive ? Color.white : Theme.secondaryText)
            .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Theme.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Macintosh HD").foregroundStyle(Theme.secondaryText)
                Spacer()
                if let snapshot = optimization.snapshot {
                    Text("\(ByteFormat.string(snapshot.diskTotal - snapshot.diskFree)) / \(ByteFormat.string(snapshot.diskTotal))")
                        .foregroundStyle(Theme.faintText)
                }
            }
            .font(.system(size: 12))
            UsageBar(fraction: optimization.snapshot?.diskUsedFraction ?? 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
    }
}
