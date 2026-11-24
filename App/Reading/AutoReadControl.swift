import SwiftUI

/// A single transport row inside the reading tools. Changing pace is not a play command.
@MainActor
struct AutoReadControl: View {
    @ObservedObject var session: AutoReadSession
    let mode: AutoReadMode
    let available: Bool
    let appearance: ReaderToolAppearance
    let start: @MainActor () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicType

    private enum PaceDisplayStyle {
        case regular, compact, stacked
    }

    private var controlsEnabled: Bool {
        available || session.isRunning
    }

    private var playTitle: String {
        session.isRunning ? "暂停自动阅读" : "自动阅读"
    }

    private var playSymbol: String {
        session.isRunning ? "pause.fill" : "play.fill"
    }

    private var paceCategoryTitle: String {
        mode == .paged ? "翻页间隔" : "慢滑速度"
    }

    private var paceSymbol: String {
        mode == .paged ? "timer" : "speedometer"
    }

    private var pace: String {
        mode == .paged ? "每页 \(session.seconds) 秒" : speedTitle(session.speed)
    }

    private var controlCornerRadius: CGFloat {
        session.isRunning ? 13 : ReaderVisualStyle.controlCornerRadius
    }

    private var controlFont: Font {
        dynamicType.isAccessibilitySize ? .body : .subheadline
    }

    private var symbolFont: Font {
        (dynamicType.isAccessibilitySize ? Font.body : .footnote).weight(.semibold)
    }

    private var chevronFont: Font {
        (dynamicType.isAccessibilitySize ? Font.footnote : .caption2).weight(.semibold)
    }

    private var paceBackground: Color {
        if appearance.theme == .dark {
            return appearance.surface
        }
        return appearance.reduceTransparency ? appearance.card : appearance.card.opacity(0.82)
    }

    private func speedTitle(_ speed: Int) -> String {
        switch speed {
        case 12: "慢速"
        case 24: "舒缓"
        case 36: "适中"
        case 48: "快速"
        default: "更快"
        }
    }

    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                stackedLayout
            } else {
                AdaptiveAutoReadLayout(
                    horizontalSpacing: session.isRunning ? 6 : 8,
                    verticalSpacing: 6,
                    expandGap: !session.isRunning
                ) {
                    playControl(fillsWidth: false)
                    paceMenu(style: .regular)
                }
            }
        }
        .padding(.horizontal, session.isRunning ? 0 : (dynamicType.isAccessibilitySize ? 16 : 8))
        .padding(.vertical, session.isRunning ? 0 : (dynamicType.isAccessibilitySize ? 10 : 6))
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            playControl(fillsWidth: true)
            paceMenu(style: .stacked)
        }
    }

    private func playControl(fillsWidth: Bool) -> some View {
        Button {
            if session.isRunning {
                session.stop()
            } else if available {
                start()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: playSymbol)
                    .font(symbolFont)
                    .accessibilityHidden(true)
                Text(playTitle)
                    .font(controlFont.weight(.semibold))
                    .multilineTextAlignment(fillsWidth ? .center : .leading)
                    .fixedSize(horizontal: !fillsWidth, vertical: fillsWidth)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(
            AutoReadPlayButtonStyle(
                appearance: appearance,
                isRunning: session.isRunning,
                cornerRadius: controlCornerRadius,
                fillsWidth: fillsWidth
            )
        )
        .disabled(!controlsEnabled)
        .accessibilityLabel(playTitle)
        .accessibilityHint(session.isRunning ? "停止后可手动阅读" : "轻点正文也可以暂停")
        .accessibilityIdentifier("reader.autoRead.play")
    }

    private func paceMenu(style: PaceDisplayStyle) -> some View {
        let fillsWidth = style == .stacked
        return Menu {
            ForEach(mode == .paged ? AutoReadSession.intervals : AutoReadSession.speeds, id: \.self) { value in
                Button {
                    session.choose(value, for: mode)
                } label: {
                    let text = mode == .paged ? "每页 \(value) 秒" : speedTitle(value)
                    if (mode == .paged ? session.seconds : session.speed) == value {
                        Label(text, systemImage: "checkmark")
                    } else {
                        Text(text)
                    }
                }
            }
        } label: {
            paceLabelContent(style: style)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(
                    minWidth: ReaderVisualStyle.minimumControlHeight,
                    maxWidth: fillsWidth ? .infinity : nil,
                    minHeight: ReaderVisualStyle.minimumControlHeight,
                    alignment: fillsWidth ? .leading : .center
                )
                .background(
                    paceBackground,
                    in: RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
                        .strokeBorder(
                            appearance.edge.opacity(appearance.theme == .dark ? 0.95 : 0.85),
                            lineWidth: 0.75
                        )
                        .allowsHitTesting(false)
                }
                .contentShape(RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous))
        }
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.38)
        .accessibilityLabel(paceCategoryTitle)
        .accessibilityValue(pace)
        .accessibilityIdentifier("reader.autoRead.pace")
    }

    @ViewBuilder
    private func paceLabelContent(style: PaceDisplayStyle) -> some View {
        switch style {
        case .stacked:
            HStack(spacing: 8) {
                Image(systemName: paceSymbol)
                    .font(symbolFont)
                    .foregroundStyle(appearance.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(paceCategoryTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(appearance.secondary)
                    Text(pace)
                        .font(controlFont.weight(.medium))
                        .foregroundStyle(appearance.foreground)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(chevronFont)
                    .foregroundStyle(appearance.secondary)
                    .accessibilityHidden(true)
            }
        case .regular, .compact:
            HStack(spacing: 5) {
                Image(systemName: paceSymbol)
                    .font(symbolFont)
                    .foregroundStyle(appearance.secondary)
                    .accessibilityHidden(true)
                if mode == .scroll && style == .regular {
                    Text("速度")
                        .font(controlFont)
                        .foregroundStyle(appearance.secondary)
                    Text("·")
                        .font(controlFont)
                        .foregroundStyle(appearance.secondary)
                        .accessibilityHidden(true)
                }
                Text(pace)
                    .font(controlFont.weight(.medium))
                    .foregroundStyle(appearance.foreground)
                Image(systemName: "chevron.up.chevron.down")
                    .font(chevronFont)
                    .foregroundStyle(appearance.secondary)
                    .padding(.leading, 1)
                    .accessibilityHidden(true)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

@MainActor
private struct AutoReadPlayButtonStyle: ButtonStyle {
    let appearance: ReaderToolAppearance
    let isRunning: Bool
    let cornerRadius: CGFloat
    let fillsWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var foregroundColor: Color {
        if isRunning {
            return appearance.theme == .dark ? appearance.surface : appearance.elevatedSurface
        }
        return appearance.accent
    }

    private func backgroundFill(pressed: Bool) -> Color {
        if isRunning {
            return appearance.accent.opacity(pressed ? 0.84 : 1)
        }
        if appearance.reduceTransparency {
            return pressed ? appearance.accentSoft : appearance.selectedControl
        }
        let opacity = pressed
            ? (appearance.theme == .dark ? 0.28 : 0.18)
            : (appearance.theme == .dark ? 0.18 : 0.11)
        return appearance.accent.opacity(opacity)
    }

    private var strokeColor: Color {
        if isRunning {
            return Color.white.opacity(appearance.theme == .dark ? 0.16 : 0.20)
        }
        return appearance.accent.opacity(appearance.theme == .dark ? 0.36 : 0.24)
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        let animatePress = isEnabled && !reduceMotion
        return configuration.label
            .foregroundStyle(foregroundColor)
            .frame(
                minWidth: ReaderVisualStyle.minimumControlHeight,
                maxWidth: fillsWidth ? .infinity : nil,
                minHeight: ReaderVisualStyle.minimumControlHeight,
                alignment: .center
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundFill(pressed: pressed))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(strokeColor, lineWidth: isRunning ? 0.65 : 0.8)
                    }
                    .allowsHitTesting(false)
                    .animation(
                        animatePress ? ReaderMotion.pressFeedback : nil,
                        value: animatePress ? (pressed ? 1 : 2) : 0
                    )
                    .transaction { transaction in
                        if !animatePress { transaction.animation = nil }
                    }
            }
            .opacity(isEnabled ? 1 : 0.38)
    }
}

@MainActor
private struct AdaptiveAutoReadLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let expandGap: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let first = subviews[0].sizeThatFits(.unspecified)
        let second = subviews[1].sizeThatFits(.unspecified)
        let requiredHorizontal = first.width + horizontalSpacing + second.width
        if let proposedWidth = proposal.width, proposedWidth.isFinite, requiredHorizontal > proposedWidth + 0.5 {
            let wrappedFirst = subviews[0].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            let wrappedSecond = subviews[1].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            return CGSize(
                width: min(proposedWidth, max(wrappedFirst.width, wrappedSecond.width)),
                height: wrappedFirst.height + verticalSpacing + wrappedSecond.height
            )
        }
        let width: CGFloat
        if expandGap, let proposedWidth = proposal.width, proposedWidth.isFinite {
            width = max(requiredHorizontal, proposedWidth)
        } else {
            width = requiredHorizontal
        }
        return CGSize(width: width, height: max(first.height, second.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let first = subviews[0].sizeThatFits(.unspecified)
        let second = subviews[1].sizeThatFits(.unspecified)
        let requiredHorizontal = first.width + horizontalSpacing + second.width
        if requiredHorizontal > bounds.width + 0.5 {
            let wrappedFirst = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let wrappedSecond = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                              proposal: ProposedViewSize(width: wrappedFirst.width, height: wrappedFirst.height))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + wrappedFirst.height + verticalSpacing),
                              proposal: ProposedViewSize(width: wrappedSecond.width, height: wrappedSecond.height))
        } else {
            let firstY = bounds.midY - first.height / 2
            let secondY = bounds.midY - second.height / 2
            subviews[0].place(at: CGPoint(x: bounds.minX, y: firstY),
                              proposal: ProposedViewSize(width: first.width, height: first.height))
            let secondX = expandGap ? (bounds.maxX - second.width) : (bounds.minX + first.width + horizontalSpacing)
            subviews[1].place(at: CGPoint(x: secondX, y: secondY),
                              proposal: ProposedViewSize(width: second.width, height: second.height))
        }
    }
}
