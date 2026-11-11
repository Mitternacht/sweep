import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            DriveDetailView()
        }
        .task { model.start() }
        .sheet(isPresented: $model.isShowingCleanSheet) {
            CleanSheet()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshVolumes()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshVolumes()
            model.recheckPermissions()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedVolumeID) {
            Section("Drives") {
                ForEach(model.volumes) { volume in
                    VolumeRow(volume: volume)
                        .tag(volume.id)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct VolumeRow: View {
    let volume: Volume

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text(volume.freeBytes, format: .byteCount(style: .file, spellsOutZero: false))
                        .monospacedDigit()
                    Text(" free")
                }
                .font(.caption)
                .foregroundStyle(volume.freeFraction < 0.1 ? Color.orange : Color.secondary)
                CapacityBar(volume: volume, height: 4)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The detail column

struct DriveDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var showsInspector = true

    var body: some View {
        @Bindable var model = model

        Group {
            if let volume = model.selectedVolume {
                switch model.mode {
                case .cleanUp: CleanUpView(volume: volume)
                case .explore: ExploreView(volume: volume)
                }
            } else {
                ContentUnavailableView("No Drive Selected", systemImage: "externaldrive", description: Text("Pick a drive in the sidebar."))
            }
        }
        .navigationTitle(model.selectedVolume?.name ?? "Sweep")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.mode) {
                    ForEach(AppModel.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Scan Again", systemImage: "arrow.clockwise") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
                    .help("Scan again (⌘R)")
                Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .help("Show or hide details")
            }
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                switch model.mode {
                case .cleanUp: FindingInspector()
                case .explore: ExploreInspector()
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
    }

    private var subtitle: String {
        guard let volume = model.selectedVolume else { return "" }
        let free = volume.freeBytes.formatted(.byteCount(style: .file, spellsOutZero: false))
        let total = volume.totalBytes.formatted(.byteCount(style: .file, spellsOutZero: false))
        return "\(free) free of \(total)"
    }
}
