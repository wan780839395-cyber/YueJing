import SwiftUI

@MainActor
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("阅境")
                .font(.largeTitle.bold())

            Text("准备中")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
