import ReaderDomain
import SwiftUI

@MainActor
struct ReaderDiagnosticsView: View {
    var importState: ImportDiagnosticState?
    var importSummary: String?
    var openingSummary: String?
    var body: some View {
        List {
            Section {
                Text("仅本机固定阶段和时长，不包含书名、路径、正文或书籍校验值。窗口已应用不等于真实首绘。")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
            if let state = importState {
                Section("本次导入") {
                    if state.attempt == nil { Text("本次尚无导入记录。") }
                    else {
                        Text(state.callbackSummary)
                        if let stage = state.stage { Text("阶段：\(stage.label)") }
                        if let failure = state.failure { Text(failure.summary) }
                        if let failedAfter = state.failedAfter { Text("出错前：\(failedAfter.label)") }
                        DisclosureGroup("阶段记录") {
                            ForEach(Array(state.history.enumerated()), id: \.offset) { item in
                                Text("\(item.offset + 1). \(item.element.label)")
                            }
                        }
                    }
                    if let importSummary { Text(importSummary).textSelection(.enabled) }
                }
            }
            if importState == nil || openingSummary != nil {
                Section("本次打开") {
                    Text(openingSummary ?? "尚未应用首个正文窗口。").textSelection(.enabled)
                }
            }
        }
        .navigationTitle("诊断与耗时").navigationBarTitleDisplayMode(.inline)
    }
}
