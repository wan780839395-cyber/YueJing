import SwiftUI

@MainActor
struct ReaderSpeechControl: View {
    @ObservedObject var session: ReaderSpeechSession
    let available: Bool
    let start: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if session.isActive {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { transport }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 0) { transport }
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
            Picker("朗读语速", selection: $session.rate) {
                ForEach(ReaderSpeechRate.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: { Text("语速：\(session.rate.rawValue)").frame(minHeight: 44) }
        .accessibilityHint("从下一句开始使用所选语速")
        .accessibilityIdentifier("reader.speech.rate")
        Button { session.stop() } label: { Text("结束听书").frame(minHeight: 44) }
            .accessibilityIdentifier("reader.speech.stop")
    }
}
