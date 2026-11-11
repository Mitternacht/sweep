import SwiftUI
import AppKit

struct ExploreView: View {
    let volume: Volume
    @Environment(AppModel.self) private var model

    var body: some View {
        let explorer = model.explorer

        VStack(spacing: 0) {
            PathBar()
            Divider()
            ZStack {
                switch explorer.style {
                case .list: ExploreList()
                case .map: TreemapView()
                }
                if explorer.rows.isEmpty {
                    emptyState(explorer)
                }
            }
        }
        .task(id: volume.id) { explorer.open(volume) }
    }

    @ViewBuilder
    private func emptyState(_ explorer: ExplorerModel) -> some View {
        if explorer.isMeasuringRoot {
            ProgressView("Measuring…")
        } else {
            ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("There's nothing in here."))
        }
    }
}

// MARK: - Path bar

struct PathBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var explorer = model.explorer
        let crumbs = explorer.breadcrumbs

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Enclosing Folder", systemImage: "chevron.up") { explorer.goUp() }
                    .labelStyle(.iconOnly)
                    .disabled(crumbs.count <= 1)
                    .help("Go up one folder")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(crumbs) { crumb in
                            if crumb.id != crumbs.first?.id {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            Button(crumb.name) { explorer.navigate(to: crumb.path) }
                                .buttonStyle(.plain)
                                .fontWeight(crumb.id == crumbs.last?.id ? .semibold : .regular)
                                .foregroundStyle(crumb.id == crumbs.last?.id ? Color.primary : Color.secondary)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)

                Spacer(minLength: 0)

                Picker("Style", selection: $explorer.style) {
                    Label("List", systemImage: "list.bullet").tag(ExplorerModel.Style.list)
                    Label("Map", systemImage: "square.grid.2x2.fill").tag(ExplorerModel.Style.map)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .frame(width: 84)
                .help("Switch between a list and a map of sizes")
            }

            if let node = explorer.current {
                Text(summary(node))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func summary(_ node: TreeNode) -> String {
        let size = node.bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
        let items = node.files.formatted(.number)
        let measuring = model.explorer.isMeasuringRoot ? " · still measuring" : ""
        return "\(size) · \(items) files\(measuring)"
    }
}

// MARK: - List

struct ExploreList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var explorer = model.explorer

        List(selection: $explorer.selectedID) {
            ForEach(explorer.rows) { row in
                ExploreRow(row: row, isMeasuring: explorer.measuring.contains(row.id))
                    .tag(row.id)
            }
            if let hidden = hiddenSummary(explorer) {
                Text(hidden)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = explorer.rows.first(where: { $0.id == id }) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.node.path)])
                }
                if row.node.isDirectory {
                    Button("Open") { explorer.open(row: row) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = explorer.rows.first(where: { $0.id == id }) {
                explorer.open(row: row)
            }
        }
    }

    private func hiddenSummary(_ explorer: ExplorerModel) -> String? {
        guard let node = explorer.current, node.hiddenCount > 0 else { return nil }
        return "and \(node.hiddenCount.formatted(.number)) smaller items · \(node.hiddenBytes.formatted(.byteCount(style: .file, spellsOutZero: false)))"
    }
}

struct ExploreRow: View {
    let row: ExplorerModel.Row
    let isMeasuring: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.node.name)
                    .font(.headline)
                    .lineLimit(1)
                context
                    .font(.subheadline)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isMeasuring && row.node.bytes == 0 {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    Text(row.node.bytes, format: .byteCount(style: .file, spellsOutZero: false))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                    SizeBar(fraction: row.fraction, tint: barTint)
                        .frame(width: 84)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if row.lockReason != nil {
            Image(systemName: "lock.fill").font(.title3).foregroundStyle(.secondary)
        } else if row.node.isDirectory {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.accentColor.opacity(0.85))
        } else {
            Image(systemName: "doc.fill").font(.title3).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var context: some View {
        if let reason = row.lockReason {
            Text("Protected · \(reason)").foregroundStyle(.secondary)
        } else if let finding = row.finding {
            HStack(spacing: 6) {
                SafetyBadge(safety: finding.safety)
                Text(finding.title).foregroundStyle(.secondary)
            }
        } else if let note = row.note {
            Text(note).foregroundStyle(.secondary)
        } else if row.node.isDirectory {
            Text("\(row.node.files.formatted(.number)) files").foregroundStyle(.secondary)
        } else if let date = row.node.newest {
            Text("Changed \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))").foregroundStyle(.secondary)
        }
    }

    private var barTint: Color {
        if row.lockReason != nil { return .secondary }
        return row.finding?.safety.tint ?? .accentColor
    }
}

// MARK: - Inspector

struct ExploreInspector: View {
    @Environment(AppModel.self) private var model
    @State private var pendingTrash: ExplorerModel.Row?

    var body: some View {
        let explorer = model.explorer

        Group {
            if let row = explorer.selectedRow {
                details(of: row, explorer: explorer)
            } else if let node = explorer.current {
                folderSummary(node)
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "sidebar.right")
            }
        }
        .confirmationDialog("Move to Trash?", item: $pendingTrash) { row in
            Button("Move “\(row.node.name)” to Trash", role: .destructive) {
                Task { await explorer.moveToTrash(row) }
            }
        } message: { row in
            Text("\(row.node.bytes.formatted(.byteCount(style: .file, spellsOutZero: false))) will move to the Trash. You can put it back until you empty the Trash.")
        }
    }

    private func details(of row: ExplorerModel.Row, explorer: ExplorerModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: row.lockReason != nil ? "lock.fill" : (row.node.isDirectory ? "folder.fill" : "doc.fill"))
                            .font(.title)
                            .foregroundStyle(row.lockReason != nil ? Color.secondary : Color.accentColor)
                            .frame(width: 40)
                        Text(row.node.name).font(.title3.weight(.semibold)).lineLimit(2)
                    }
                    if let finding = row.finding { SafetyBadge(safety: finding.safety) }
                    ForEach(row.finding?.blockedBy ?? [], id: \.message) { blocker in
                        Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(row.node.isDirectory ? "Files" : "Changed").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    GridRow {
                        Text(row.node.bytes, format: .byteCount(style: .file, spellsOutZero: false)).font(.title3.weight(.semibold)).monospacedDigit()
                        if row.node.isDirectory {
                            Text(row.node.files, format: .number).font(.title3).monospacedDigit()
                        } else if let date = row.node.newest {
                            Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated)).font(.title3)
                        }
                    }
                }

                if let reason = row.lockReason {
                    InspectorSection("Protected") {
                        Text("\(reason). Sweep won't delete this. Use Finder if you really want it gone.")
                    }
                }
                if let note = row.note {
                    InspectorSection("What it is") { Text(note) }
                }
                if let finding = row.finding {
                    InspectorSection("What it is") { Text(finding.what) }
                    InspectorSection("If you delete it") { Text(finding.consequence) }
                }

                InspectorSection("Where") { LocationRow(path: row.node.path) }

                actions(row: row, explorer: explorer)

                if let message = explorer.trashError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(row.id)
    }

    @ViewBuilder
    private func actions(row: ExplorerModel.Row, explorer: ExplorerModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.node.isDirectory {
                Button("Open Folder", systemImage: "folder") { explorer.open(row: row) }
            }
            if row.finding != nil, row.finding?.canClean == true {
                Button("Show in Clean Up", systemImage: "sparkles") {
                    model.mode = .cleanUp
                    model.focusedID = row.finding?.id
                }
            }
            if row.lockReason == nil {
                Button("Move to Trash…", systemImage: "trash", role: .destructive) { pendingTrash = row }
                    .disabled(!explorer.canTrash(row))
            }
        }
        .controlSize(.regular)
    }

    private func folderSummary(_ node: TreeNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.title).foregroundStyle(Color.accentColor).frame(width: 40)
                    Text(node.name).font(.title3.weight(.semibold)).lineLimit(2)
                }
                if let note = PathContext.note(for: node.path) {
                    InspectorSection("What it is") { Text(note) }
                }
                InspectorSection("Where") { LocationRow(path: node.path) }
                Text("Select something in the list to see what it is and what happens if you remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Treemap

/// Every item in the folder as a tile, sized by how much space it takes.
/// Green tiles are safe to clean, orange ones are worth a look, grey ones are protected.
struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: String?

    private struct Tile: Identifiable {
        var id: String
        var row: ExplorerModel.Row?
        var title: String
        var bytes: Int64
    }

    var body: some View {
        @Bindable var explorer = model.explorer
        let tiles = makeTiles(explorer)

        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 12, dy: 12)
            let rects = Squarify.layout(values: tiles.map { Double($0.bytes) }, in: bounds)

            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(tiles, rects)), id: \.0.id) { tile, rect in
                    tileView(tile, rect: rect, explorer: explorer)
                }
            }
            .motion(.smooth(duration: 0.35), value: tiles.map(\.id))
        }
        .accessibilityElement()
        .accessibilityLabel("Map of folder sizes")
        .accessibilityHint("Switch to the list view to hear every item.")
    }

    private func makeTiles(_ explorer: ExplorerModel) -> [Tile] {
        let sized = explorer.rows.filter { $0.node.bytes > 0 }.sorted { $0.node.bytes > $1.node.bytes }
        var tiles = sized.prefix(36).map { Tile(id: $0.id, row: $0, title: $0.node.name, bytes: $0.node.bytes) }
        let rest = sized.dropFirst(36)
        let leftover = rest.reduce(Int64(0)) { $0 + $1.node.bytes } + (explorer.current?.hiddenBytes ?? 0)
        if leftover > 0 { tiles.append(Tile(id: "other", row: nil, title: "Smaller items", bytes: leftover)) }
        return tiles
    }

    /// The biggest items inside a large folder, drawn as smaller tiles within its tile.
    /// Double-click one to jump straight into it.
    @ViewBuilder
    private func insideTiles(of kids: [TreeNode], in size: CGSize, parent: Tile, explorer: ExplorerModel) -> some View {
        let shown = Array(kids.filter { $0.bytes > 0 }.prefix(24))
        let area = CGRect(x: 6, y: 36, width: size.width - 12, height: size.height - 42)
        let rects = Squarify.layout(values: shown.map { Double($0.bytes) }, in: area)

        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(shown, rects)), id: \.0.id) { kid, rect in
                let box = rect.insetBy(dx: 1, dy: 1)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(insideFill(explorer.context(forPath: kid.path)))
                    .overlay(alignment: .topLeading) {
                        if box.width > 64, box.height > 30 {
                            Text(kid.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(4)
                                .foregroundStyle(.primary.opacity(0.8))
                        }
                    }
                    .frame(width: max(0, box.width), height: max(0, box.height))
                    .offset(x: box.minX, y: box.minY)
                    .onTapGesture(count: 2) { explorer.navigate(to: kid.path) }
                    .onTapGesture { explorer.selectedID = parent.id }
                    .help("\(kid.name) · \(kid.bytes.formatted(.byteCount(style: .file, spellsOutZero: false)))")
            }
        }
    }

    private func insideFill(_ info: (lockReason: String?, finding: Finding?)) -> Color {
        if info.lockReason != nil { return Color.gray.opacity(0.35) }
        switch info.finding?.safety {
        case .safe: return Color.green.opacity(0.5)
        case .review: return Color.orange.opacity(0.5)
        default: return Color.primary.opacity(0.10)
        }
    }

    @ViewBuilder
    private func tileView(_ tile: Tile, rect: CGRect, explorer: ExplorerModel) -> some View {
        let isSelected = tile.id == explorer.selectedID
        let frame = rect.insetBy(dx: 1.5, dy: 1.5)

        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(fill(for: tile))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(hovered == tile.id ? 0.35 : 0.08), lineWidth: isSelected ? 2.5 : 1)
            }
            .overlay(alignment: .topLeading) {
                if frame.width > 150, frame.height > 100, let kids = tile.row?.node.children, !kids.isEmpty {
                    insideTiles(of: kids, in: frame.size, parent: tile, explorer: explorer)
                }
            }
            .overlay(alignment: .topLeading) {
                if frame.width > 84, frame.height > 46 {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if tile.row?.lockReason != nil { Image(systemName: "lock.fill").font(.caption2) }
                            Text(tile.title).font(.callout.weight(.semibold)).lineLimit(1)
                        }
                        Text(tile.bytes, format: .byteCount(style: .file, spellsOutZero: false))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
            }
            .frame(width: max(0, frame.width), height: max(0, frame.height))
            .offset(x: frame.minX, y: frame.minY)
            .onHover { inside in hovered = inside ? tile.id : (hovered == tile.id ? nil : hovered) }
            .onTapGesture(count: 2) {
                if let row = tile.row { explorer.open(row: row) }
            }
            .onTapGesture {
                if tile.row != nil { explorer.selectedID = tile.id }
            }
            .help("\(tile.title) · \(tile.bytes.formatted(.byteCount(style: .file, spellsOutZero: false)))")
    }

    private func fill(for tile: Tile) -> Color {
        guard let row = tile.row else { return Color.primary.opacity(0.06) }
        if row.lockReason != nil { return Color.gray.opacity(0.30) }
        switch row.finding?.safety {
        case .safe: return Color.green.opacity(0.38)
        case .review: return Color.orange.opacity(0.38)
        default: return row.node.isDirectory ? Color.blue.opacity(0.20) : Color.secondary.opacity(0.20)
        }
    }
}
