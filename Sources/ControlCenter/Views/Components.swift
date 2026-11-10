import SwiftUI

/// `SwiftUI.State`, spelled out. Recent SDKs also export an unrelated `State`
/// macro, which makes a bare `@State` ambiguous.
typealias ViewState<Value> = SwiftUI.State<Value>

// MARK: - Status

enum StatusLevel {
    case good, attention, inactive

    var color: Color {
        switch self {
        case .good: return .green
        case .attention: return .orange
        case .inactive: return .secondary
        }
    }
}

/// A colored dot followed by a short description of the current state.
struct StatusLabel: View {
    let text: String
    let level: StatusLevel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(level.color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

/// A leading symbol, a title, and a secondary line: the basic row used throughout the app.
struct DetailRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 2)
    }
}

extension DetailRow where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// One line of a short numbered procedure.
struct NumberedStep: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) { self.number = number; self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "\(number).circle").foregroundStyle(.secondary)
        }
    }
}

/// An inline prompt shown where a feature is blocked by a missing macOS permission.
struct PermissionNotice: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
        }
    }
}

/// Explanatory text under a form section. Grouped forms right-align a bare
/// footer `Text` on macOS, which reads poorly for full sentences.
struct SectionFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sliders

/// A slider with a fixed-width, right-aligned readout, so stacked rows line up.
/// Snapping is left to the caller: a stepped SwiftUI slider draws one tick per
/// step, which is unreadable for ranges such as 200–8000 DPI.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let readout: String
    var onCommit: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit() }
            }
            .frame(minWidth: 140, maxWidth: 280)
            Text(readout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
        }
    }
}

// MARK: - Logitech thumb controls

/// HID++ control IDs for the two MX Master thumb buttons hold-to-dictate can use.
enum ThumbControl {
    static let haptic = 0x01a0
    static let gesture = 0x00c3
    static let all = [haptic, gesture]

    static func name(_ controlID: Int) -> String {
        controlID == haptic ? "Haptic thumb button" : "Gesture button"
    }
}
