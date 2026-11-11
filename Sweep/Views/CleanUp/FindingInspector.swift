import SwiftUI
import AppKit

/// The "which context" panel: what the selected item is, where it lives and what happens if it goes.
struct FindingInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let finding = model.focusedFinding {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(finding)
                    stats(finding)

                    InspectorSection("What it is") {
                        Text(finding.what)
                    }
                    InspectorSection("If you delete it") {
                        Text(finding.consequence)
                    }
                    InspectorSection("Where") {
                        LocationRow(path: finding.url.path)
                    }
                    if !finding.breakdown.isEmpty {
                        InspectorSection("What's inside") {
                            breakdown(finding)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(finding.id)
        } else {
            ContentUnavailableView(
                "Select an Item",
                systemImage: "sidebar.right",
                description: Text("See what it is, where it lives and what happens if you delete it.")
            )
        }
    }

    private func header(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CategoryIcon(category: finding.category, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(finding.category.title).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            SafetyBadge(safety: finding.safety)
            ForEach(finding.blockedBy, id: \.message) { blocker in
                Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func stats(_ finding: Finding) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text("Items").foregroundStyle(.secondary)
                Text("Last changed").foregroundStyle(.secondary)
            }
            .font(.caption)
            GridRow {
                Text(finding.bytes, format: .byteCount(style: .file, spellsOutZero: false)).font(.title3.weight(.semibold)).monospacedDigit()
                Text(finding.fileCount, format: .number).font(.title3).monospacedDigit()
                if let date = finding.lastChanged {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated)).font(.title3)
                } else {
                    Text("–").font(.title3)
                }
            }
        }
    }

    private func breakdown(_ finding: Finding) -> some View {
        let largest = finding.breakdown.first?.bytes ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(finding.breakdown) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(item.bytes, format: .byteCount(style: .file, spellsOutZero: false))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    SizeBar(fraction: Double(item.bytes) / Double(max(largest, 1)), tint: .secondary)
                }
            }
        }
        .font(.callout)
    }
}

// MARK: - Shared inspector pieces

struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A path you can read, reveal in Finder or copy.
struct LocationRow: View {
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PathUtil.abbreviated(path))
                .font(.callout.monospaced())
                .textSelection(.enabled)
            HStack {
                Button("Reveal in Finder", systemImage: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("Copy Path", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            .controlSize(.small)
        }
    }
}
