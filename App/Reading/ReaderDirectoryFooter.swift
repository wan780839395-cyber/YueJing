import SwiftUI

/// In-flow sheet footer. It does not own a model, request state or reading viewport space.
@MainActor
struct ReaderDirectoryFooter: View {
    let rangeLabel: String
    let loading: Bool
    let previousDisabled: Bool
    let nextDisabled: Bool
    let appearance: ReaderToolAppearance
    let requestCurrent: @MainActor () -> Void
    let loadPrevious: @MainActor () -> Void
    let loadNext: @MainActor () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicType

    private static let loadingSlotWidth: CGFloat = 16

    var body: some View {
        VStack(spacing: 8) {
            if verticalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(appearance.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var regularLayout: some View {
        currentButton(fillsWidth: true, iconOnly: false)
        if dynamicType.isAccessibilitySize {
            VStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        previousButton(fillsWidth: false)
                        Spacer(minLength: 8)
                        nextButton(fillsWidth: false)
                    }
                    VStack(spacing: 8) {
                        previousButton(fillsWidth: true)
                        nextButton(fillsWidth: true)
                    }
                }
                rangeText(singleLine: false)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    previousButton(fillsWidth: false)
                    Spacer(minLength: 8)
                    rangeText(singleLine: true)
                    Spacer(minLength: 8)
                    nextButton(fillsWidth: false)
                }
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        previousButton(fillsWidth: false)
                        Spacer(minLength: 8)
                        nextButton(fillsWidth: false)
                    }
                    rangeText(singleLine: false)
                }
                VStack(spacing: 8) {
                    previousButton(fillsWidth: true)
                    nextButton(fillsWidth: true)
                    rangeText(singleLine: false)
                }
            }
        }
    }

    @ViewBuilder
    private var compactLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                currentButton(fillsWidth: false, iconOnly: true)
                previousButton(fillsWidth: false)
                Spacer(minLength: 8)
                rangeText(singleLine: true)
                Spacer(minLength: 8)
                nextButton(fillsWidth: false)
            }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    currentButton(fillsWidth: false, iconOnly: true)
                    Spacer(minLength: 8)
                    previousButton(fillsWidth: false)
                    nextButton(fillsWidth: false)
                }
                rangeText(singleLine: false)
            }
            VStack(spacing: 6) {
                currentButton(fillsWidth: true, iconOnly: false)
                previousButton(fillsWidth: true)
                nextButton(fillsWidth: true)
                rangeText(singleLine: false)
            }
        }
    }

    private func currentButton(fillsWidth: Bool, iconOnly: Bool) -> some View {
        Button(action: requestCurrent) {
            Group {
                if iconOnly {
                    Label("回到当前章节", systemImage: "scope").labelStyle(.iconOnly)
                } else {
                    Label("回到当前章节", systemImage: "scope").labelStyle(.titleAndIcon)
                }
            }
            .font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: !fillsWidth, vertical: true)
            .padding(.horizontal, iconOnly ? 10 : 14)
            .padding(.vertical, 8)
            .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil,
                   minHeight: ReaderVisualStyle.minimumControlHeight)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground))
        .accessibilityLabel("回到当前章节")
    }

    private func previousButton(fillsWidth: Bool) -> some View {
        pagingButton("上一组", disabled: previousDisabled, fillsWidth: fillsWidth, action: loadPrevious)
    }

    private func nextButton(fillsWidth: Bool) -> some View {
        pagingButton("下一组", disabled: nextDisabled, fillsWidth: fillsWidth, action: loadNext)
    }

    private func pagingButton(_ title: LocalizedStringKey, disabled: Bool, fillsWidth: Bool,
                              action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: !fillsWidth, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil,
                       minHeight: ReaderVisualStyle.minimumControlHeight)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground))
        .disabled(disabled)
    }

    private func rangeText(singleLine: Bool) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "hourglass")
                .font(.caption2)
                .foregroundStyle(appearance.accent)
                .frame(width: Self.loadingSlotWidth)
                .opacity(loading ? 1 : 0)
                .accessibilityHidden(true)
            Text(rangeLabel)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(appearance.foreground.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: singleLine, vertical: true)
            Color.clear
                .frame(width: Self.loadingSlotWidth, height: 1)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: singleLine, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("目录范围，\(rangeLabel)")
        .accessibilityValue(loading ? "正在读取目录" : "")
    }
}
