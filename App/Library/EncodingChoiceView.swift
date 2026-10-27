import ReaderDomain
import SwiftUI
import TXTCore

@MainActor
struct EncodingChoiceView: View {
    let choice: EncodingChoice
    let select: @MainActor (TXTEncoding) -> Void
    let cancel: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("同一段文字有几种识别结果。请选择读起来正常的一份；也可以取消，书架不会新增记录。")
                        .foregroundStyle(.secondary)
                    ForEach(choice.cards) { card in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(card.title).font(.headline)
                            Text(card.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Button("使用这份文字") { select(card.encoding) }.buttonStyle(.borderedProminent)
                        }
                        .padding().background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding()
            }
            .navigationTitle("确认文字")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) } }
        }
    }
}
