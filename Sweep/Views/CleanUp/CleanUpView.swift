import SwiftUI

struct CleanUpView: View {
    let volume: Volume
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.focusedID) {
            Section {
                OverviewHeader(volume: volume)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
            }
            .selectionDisabled()

            if !model.safeFindings.isEmpty {
                FindingSection(
                    title: "Safe to clean",
                    detail: "These rebuild or download again by themselves.",
                    findings: model.safeFindings
                )
            }
            if !model.reviewFindings.isEmpty {
                FindingSection(
                    title: "Review first",
                    detail: "Probably stale, but only you can tell. Sent to the Trash by default.",
                    findings: model.reviewFindings
                )
            }
            if showsEmptyState {
                Section {
                    ContentUnavailableView(
                        "Nothing to clean here",
                        systemImage: "checkmark.seal",
                        description: Text("Sweep found no build leftovers, caches or test files it understands on this drive. Try Explore to see where the space went.")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                }
                .selectionDisabled()
            }

            ProtectedSection()
                .selectionDisabled()
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar()
        }
    }

    private var showsEmptyState: Bool {
        model.scanPhase == .finished && model.safeFindings.isEmpty && model.reviewFindings.isEmpty
    }
}

// MARK: - Header

struct OverviewHeader: View {
    let volume: Volume
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.safeBytes, format: .byteCount(style: .file, spellsOutZero: false))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("can be cleaned safely")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            CapacityBar(volume: volume, safeBytes: model.safeBytes, reviewBytes: model.reviewBytes)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { legend }
                VStack(alignment: .leading, spacing: 6) { legend }
            }

            ScanStatus()

            if !model.hasFullDiskAccess, !model.dismissedAccessBanner {
                AccessBanner()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var legend: some View {
        LegendItem(color: .green, title: "Safe", bytes: model.safeBytes)
        LegendItem(color: .orange, title: "Review", bytes: model.reviewBytes)
        LegendItem(color: Color.primary.opacity(0.24), title: "Other", bytes: max(0, volume.usedBytes - model.safeBytes - model.reviewBytes))
        LegendItem(color: Color.primary.opacity(0.1), title: "Free", bytes: volume.freeBytes)
    }
}

/// "Looking through 63 places" while a scan runs.
struct ScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .scanning(let done, let total) = model.scanPhase {
            HStack(spacing: 10) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .frame(width: 140)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(total > 0 ? "Checking \(done) of \(total) places" : "Looking for projects and caches…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .transition(.opacity)
        }
    }
}

struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sweep can see more with Full Disk Access")
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                    Button("Not Now") { model.dismissedAccessBanner = true }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var detail: String {
        if model.needsAccess.isEmpty {
            return "Protected folders like the Trash and iPhone backups stay hidden until you allow it."
        }
        return "Couldn't look in: " + model.needsAccess.joined(separator: ", ") + "."
    }
}

// MARK: - Sections and rows

struct FindingSection: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let findings: [Finding]
    @Environment(AppModel.self) private var model

    var body: some View {
        let total = findings.reduce(Int64(0)) { $0 + $1.bytes }
        let largest = findings.first?.bytes ?? 1
        let allChecked = model.checkedState(of: findings)

        Section {
            ForEach(findings) { finding in
                FindingRow(finding: finding, largest: largest)
                    .tag(finding.id)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(total, format: .byteCount(style: .file, spellsOutZero: false))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(allChecked ? "Deselect All" : "Select All") {
                    model.setChecked(findings, to: !allChecked)
                }
                .buttonStyle(.link)
                .disabled(findings.allSatisfy { !$0.canClean })
            }
            .textCase(nil)
            .padding(.top, 4)
        }
    }
}

struct FindingRow: View {
    let finding: Finding
    let largest: Int64
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 12) {
            Toggle("Include \(finding.title)", isOn: $model[checked: finding.id])
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!finding.canClean)

            CategoryIcon(category: finding.category)

            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(finding.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let blocker = finding.blockedBy.first {
                    Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                Text(finding.bytes, format: .byteCount(style: .file, spellsOutZero: false))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                SizeBar(fraction: Double(finding.bytes) / Double(max(largest, 1)), tint: finding.safety.tint)
                    .frame(width: 84)
            }
        }
        .padding(.vertical, 5)
        .opacity(finding.canClean ? 1 : 0.62)
        .help(PathUtil.abbreviated(finding.url.path))
    }
}

// MARK: - Protected

struct ProtectedSection: View {
    private let items: [(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey)] = [
        ("bubble.left.and.text.bubble.right", "Conversation history", "Claude Code and Codex sessions and prompts"),
        ("person.fill", "Your files", "Documents, Desktop, Pictures, Movies and Music"),
        ("icloud.fill", "iCloud Drive", "Managed by iCloud, not by Sweep"),
        ("envelope.fill", "Mail, Messages and Safari", "Plus keychains, calendars and contacts"),
        ("signature", "Signing and Xcode settings", "Provisioning profiles, themes and key bindings"),
        ("key.fill", "Keys and credentials", "SSH, GPG and cloud credentials"),
        ("apple.logo", "Apps and macOS", "Installed apps and system folders"),
        ("point.3.connected.trianglepath.dotted", "Git repositories", "A folder that holds a repository is never deleted"),
    ]

    var body: some View {
        Section {
            DisclosureGroup {
                ForEach(items.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: items[index].symbol)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(items[index].title)
                            Text(items[index].detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protected").font(.headline)
                        Text("Sweep never touches these, whatever a rule says.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Action bar

struct ActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.checkedBytes, format: .byteCount(style: .file, spellsOutZero: false))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(model.checkedCount == 1 ? "1 item selected" : "\(model.checkedCount) items selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button {
                model.prepareCleanup()
            } label: {
                Text("Clean Up…")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.checkedCount == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .motion(.smooth(duration: 0.3), value: model.checkedBytes)
    }
}
