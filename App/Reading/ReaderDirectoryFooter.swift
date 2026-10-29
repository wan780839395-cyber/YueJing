import SwiftUI

/// In-flow sheet footer. It does not own a model, request state or reading viewport space.
@MainActor
struct ReaderDirectoryFooter: View {
    let rangeLabel: String
    let previousDisabled: Bool
    let nextDisabled: Bool
    let appearance: ReaderToolAppearance
    let requestCurrent: @MainActor () -> Void
    let loadPrevious: @MainActor () -> Void
    let loadNext: @MainActor () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(spacing: 4) {
            Rectangle().fill(appearance.edge)
                .frame(height: ReaderVisualStyle.panelDividerHeight)
                .accessibilityHidden(true)
            if verticalSizeClass == .compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        currentButton.fixedSize(horizontal: true, vertical: false)
                        previousButton.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        rangeText.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        nextButton.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            currentButton
                            Spacer(minLength: 8)
                            previousButton
                            nextButton
                        }
                        rangeText
                    }
                }
            } else {
                currentButton.frame(maxWidth: .infinity)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        previousButton.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        rangeText.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        nextButton.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            previousButton
                            Spacer(minLength: 8)
                            nextButton
                        }
                        rangeText
                    }
                }
            }
        }
        .font(.footnote)
        .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
        .padding(.vertical, 8)
        .background(appearance.surface)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var currentButton: some View {
        Button(action: requestCurrent) {
            Group {
                if verticalSizeClass == .compact {
                    Label("回到当前章节", systemImage: "scope").labelStyle(.iconOnly)
                } else {
                    Label("回到当前章节", systemImage: "scope").labelStyle(.titleAndIcon)
                }
            }
            .padding(.horizontal, 4)
            .frame(minWidth: 44, minHeight: ReaderVisualStyle.minimumControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent))
        .accessibilityLabel("回到当前章节")
    }

    private var previousButton: some View {
        Button(action: loadPrevious) {
            Text("上一组")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 4)
                .frame(minWidth: 44, minHeight: ReaderVisualStyle.minimumControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent))
        .disabled(previousDisabled)
    }

    private var nextButton: some View {
        Button(action: loadNext) {
            Text("下一组")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 4)
                .frame(minWidth: 44, minHeight: ReaderVisualStyle.minimumControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent))
        .disabled(nextDisabled)
    }

    private var rangeText: some View {
        Text(rangeLabel)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(appearance.foreground.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("目录范围，\(rangeLabel)")
    }
}
