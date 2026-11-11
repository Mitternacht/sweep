import SwiftUI

// MARK: - Words and colors for the model types

extension Safety {
    var tint: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .protected: .secondary
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .safe: "Safe to clean"
        case .review: "Review first"
        case .protected: "Protected"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .review: "eye.circle.fill"
        case .protected: "lock.fill"
        }
    }
}

extension Category {
    var title: LocalizedStringResource {
        switch self {
        case .xcode: "Xcode"
        case .simulators: "Simulators"
        case .packages: "Package caches"
        case .projects: "Projects"
        case .appCaches: "App caches"
        case .temp: "Temporary files"
        case .downloads: "Downloads"
        case .backups: "Backups"
        case .trash: "Trash"
        }
    }

    var symbol: String {
        switch self {
        case .xcode: "hammer.fill"
        case .simulators: "iphone"
        case .packages: "shippingbox.fill"
        case .projects: "curlybraces"
        case .appCaches: "square.stack.3d.up.fill"
        case .temp: "clock.arrow.circlepath"
        case .downloads: "arrow.down.circle.fill"
        case .backups: "archivebox.fill"
        case .trash: "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .xcode: .blue
        case .simulators: .indigo
        case .packages: .brown
        case .projects: .purple
        case .appCaches: .teal
        case .temp: .gray
        case .downloads: .cyan
        case .backups: .pink
        case .trash: .gray
        }
    }
}

// MARK: - Motion

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Animates changes to `value`, unless the person asked their Mac for less motion.
    func motion<Value: Equatable>(_ animation: Animation = .smooth(duration: 0.3), value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}

// MARK: - Small pieces

/// A rounded square with a symbol, like the icons in System Settings.
struct CategoryIcon: View {
    let category: Category
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Label {
            Text(safety.label)
        } icon: {
            Image(systemName: safety.symbol)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(safety.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(safety.tint.opacity(0.14), in: Capsule())
    }
}

/// A thin bar showing how big something is compared with its neighbours.
struct SizeBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .motion(.smooth(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// The whole drive as one bar: what Sweep can clean, what to review, everything else, and what's free.
struct CapacityBar: View {
    let volume: Volume
    var safeBytes: Int64 = 0
    var reviewBytes: Int64 = 0
    var height: CGFloat = 14

    var body: some View {
        let total = Double(max(volume.totalBytes, 1))
        let safe = Double(safeBytes) / total
        let review = Double(reviewBytes) / total
        let other = max(0, Double(volume.usedBytes) / total - safe - review)

        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 1.5) {
                segment(.green, safe, width)
                segment(.orange, review, width)
                segment(Color.primary.opacity(0.24), other, width)
                Rectangle().fill(Color.primary.opacity(0.07))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .motion(.smooth(duration: 0.4), value: safeBytes)
        .motion(.smooth(duration: 0.4), value: reviewBytes)
        .accessibilityElement()
        .accessibilityLabel("Drive usage")
        .accessibilityValue("\(volume.freeBytes.formatted(.byteCount(style: .file, spellsOutZero: false))) free of \(volume.totalBytes.formatted(.byteCount(style: .file, spellsOutZero: false)))")
    }

    @ViewBuilder
    private func segment(_ color: Color, _ fraction: Double, _ width: CGFloat) -> some View {
        if fraction > 0.0005 {
            Rectangle().fill(color).frame(width: max(2, width * fraction))
        }
    }
}

struct LegendItem: View {
    let color: Color
    let title: LocalizedStringKey
    let bytes: Int64

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(bytes, format: .byteCount(style: .file, spellsOutZero: false))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
