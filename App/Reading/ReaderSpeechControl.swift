import SwiftUI

@MainActor
struct ReaderSpeechControl: View {
    @ObservedObject var session: ReaderSpeechSession
    let available: Bool
    let start: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if session.isActive {
                AdaptiveSpeechTransportLayout(horizontalSpacing: 14, verticalSpacing: 0) {
                    transport
                }
            } else {
                Button(action: start) { Label("听书", systemImage: "headphones").frame(minHeight: 44) }
                    .disabled(!available)
                    .accessibilityHint("用系统语音从当前位置开始朗读")
                    .accessibilityIdentifier("reader.speech.start")
            }
            if let notice = session.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var transport: some View {
        let paused = session.phase == .paused
        Button { paused ? session.resume() : session.pause() } label: {
            Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill").frame(minHeight: 44)
        }
        .accessibilityLabel(paused ? "继续听书" : "暂停听书")
        .accessibilityIdentifier("reader.speech.toggle")
        Menu {
            ForEach(ReaderSpeechRate.allCases, id: \.self) { rate in
                Button {
                    session.rate = rate
                } label: {
                    if session.rate == rate {
                        Label(rate.rawValue, systemImage: "checkmark")
                    } else {
                        Text(rate.rawValue)
                    }
                }
            }
        } label: { Text("语速：\(session.rate.rawValue)").frame(minHeight: 44) }
        .accessibilityHint("从下一句开始使用所选语速")
        .accessibilityIdentifier("reader.speech.rate")
        Button { session.stop() } label: { Text("结束听书").frame(minHeight: 44) }
            .accessibilityIdentifier("reader.speech.stop")
    }
}

@MainActor
private struct AdaptiveSpeechTransportLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let totalWidth = idealSizes.reduce(0) { $0 + $1.width } + horizontalSpacing * CGFloat(max(0, idealSizes.count - 1))
        if let proposedWidth = proposal.width, totalWidth > proposedWidth + 0.5 {
            let wrapped = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil)) }
            let width = wrapped.map(\.width).max() ?? 0
            let height = wrapped.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(0, wrapped.count - 1))
            return CGSize(width: min(proposedWidth, width), height: height)
        }
        let height = idealSizes.map(\.height).max() ?? 0
        return CGSize(width: totalWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let totalWidth = idealSizes.reduce(0) { $0 + $1.width } + horizontalSpacing * CGFloat(max(0, idealSizes.count - 1))
        if totalWidth > bounds.width + 0.5 {
            var y = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
                y += size.height + verticalSpacing
            }
        } else {
            var x = bounds.minX
            for (subview, size) in zip(subviews, idealSizes) {
                let y = bounds.midY - size.height / 2
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + horizontalSpacing
            }
        }
    }
}
