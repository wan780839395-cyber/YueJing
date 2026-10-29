import SwiftUI

@MainActor
struct ReaderSettingAdjustment: View {
    let title: String
    let key: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let isActive: @MainActor () -> Bool
    let commit: @MainActor () -> Void
    @State private var dragging = false
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(spacing: 4) {
            if dynamicType.isAccessibilitySize {
                Text(title).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                controls.frame(maxWidth: .infinity)
            } else {
                HStack {
                    Text(title).font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    controls
                }
            }
            Slider(value: sliderValue, in: range, step: 1, onEditingChanged: { editing in
                dragging = editing
                if !editing, isActive() { commit() }
            })
            .frame(minHeight: 44)
            .disabled(!isActive())
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(value))")
            .accessibilityHint("也可使用加减按钮精调")
            .accessibilityIdentifier("reader.\(key).slider")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: {
                Image(systemName: "minus").font(.system(size: 16, weight: .medium))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(!isActive() || value <= range.lowerBound)
            .accessibilityLabel("减小\(title)").accessibilityIdentifier("reader.\(key).decrease")
            Text("\(Int(value))").font(.body.monospacedDigit()).frame(minWidth: 30)
                .accessibilityLabel("\(title)，\(Int(value))")
                .accessibilityIdentifier("reader.\(key).value")
            Button { step(1) } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(!isActive() || value >= range.upperBound)
            .accessibilityLabel("增大\(title)").accessibilityIdentifier("reader.\(key).increase")
        }
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { value }, set: { proposed in
            guard isActive(), proposed.isFinite else { return }
            value = min(range.upperBound, max(range.lowerBound, proposed.rounded()))
            // VoiceOver and keyboard adjustment need not start a touch-drag session.
            if !dragging { commit() }
        })
    }
    private func step(_ delta: Double) {
        guard isActive() else { return }
        value = min(range.upperBound, max(range.lowerBound, value + delta))
        commit()
    }
}
