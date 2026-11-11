import SwiftUI

/// One sheet that walks through confirm, progress and result, so the person never loses their place.
struct CleanSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.cleanPhase {
            case .confirming:
                ConfirmContent()
            case .cleaning(let done, let total, let current):
                ProgressContent(done: done, total: total, current: current)
            case .finished:
                ResultContent()
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 480)
        .interactiveDismissDisabled(isCleaning)
    }

    private var isCleaning: Bool {
        if case .cleaning = model.cleanPhase { true } else { false }
    }
}

// MARK: - Confirm

private struct ConfirmContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.checkedFindings.sorted { $0.bytes > $1.bytes }
        let shown = items.prefix(6)

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean up \(model.checkedBytes.formatted(.byteCount(style: .file, spellsOutZero: false)))?")
                    .font(.title2.weight(.semibold))
                Text(items.count == 1 ? "1 item on \(model.selectedVolume?.name ?? "this drive")" : "\(items.count) items on \(model.selectedVolume?.name ?? "this drive")")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(shown) { finding in
                    HStack(spacing: 10) {
                        CategoryIcon(category: finding.category, size: 24)
                        Text(finding.title).lineLimit(1)
                        Spacer()
                        Text(finding.bytes, format: .byteCount(style: .file, spellsOutZero: false))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    if finding.id != shown.last?.id { Divider() }
                }
                if items.count > shown.count {
                    Divider()
                    Text("and \(items.count - shown.count) more")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Safe items are deleted right away. They rebuild or download again on their own.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }

                if model.checkedReviewCount > 0 {
                    Label {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(model.checkedReviewCount) item\(model.checkedReviewCount == 1 ? "" : "s") marked Review:")
                            Picker("Review items", selection: $model.reviewMethod) {
                                Text("Move to Trash").tag(CleanMethod.moveToTrash)
                                Text("Delete now").tag(CleanMethod.deletePermanently)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text(model.reviewMethod == .moveToTrash
                                 ? "You can put them back until you empty the Trash. The space only comes back after that."
                                 : "They're gone for good and the space comes back right away.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "eye.circle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissCleanSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { model.confirmCleanup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .motion(.smooth(duration: 0.25), value: model.reviewMethod)
    }

    private var confirmTitle: LocalizedStringKey {
        model.checkedReviewCount > 0 && model.reviewMethod == .moveToTrash ? "Clean Up" : "Delete"
    }
}

// MARK: - Progress

private struct ProgressContent: View {
    let done: Int
    let total: Int
    let current: String
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleaning up…")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                HStack {
                    Text(current).lineLimit(1)
                    Spacer()
                    Text("\(min(done + 1, total)) of \(total)").monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Stop") { model.stopCleaning() }
            }
        }
        .padding(24)
    }
}

// MARK: - Result

private struct ResultContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        if let report = model.report {
            VStack(spacing: 18) {
                Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(report.failures.isEmpty ? Color.green : Color.orange)
                    .symbolEffect(.bounce, value: shown)

                let shownBytes: Int64 = shown ? report.freedBytes : 0
                VStack(spacing: 4) {
                    Text(shownBytes, format: .byteCount(style: .file, spellsOutZero: false))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("freed on \(report.volumeName)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("\(report.freeAfter.formatted(.byteCount(style: .file, spellsOutZero: false))) free now")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 10) {
                    if report.trashedBytes > 0 {
                        note("trash.fill", .secondary, "\(report.trashedBytes.formatted(.byteCount(style: .file, spellsOutZero: false))) went to the Trash. That space comes back once you empty it. Scan again and Sweep will offer to.")
                    }
                    if report.freedBytes + report.freedBytes / 5 < report.expectedBytes - report.trashedBytes, report.failures.isEmpty {
                        note("info.circle.fill", .secondary, "You may see less than the total: files can share space on disk, and macOS sometimes holds space back for a while.")
                    }
                    if !report.failures.isEmpty {
                        note("exclamationmark.triangle.fill", .orange, "\(report.failures.count) couldn't be cleaned:")
                        ForEach(report.failures.prefix(4)) { failure in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(failure.title).font(.callout.weight(.medium))
                                Text(reason(failure.outcome)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 28)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer()
                    Button("Scan Again") {
                        model.dismissCleanSheet()
                        model.rescan()
                    }
                    Button("Done") { model.dismissCleanSheet() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.smooth(duration: 0.9)) { shown = true }
                }
            }
        }
    }

    private func note(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private func reason(_ outcome: CleanOutcome) -> String {
        switch outcome {
        case .refused(let message), .failed(let message): message
        default: ""
        }
    }
}
