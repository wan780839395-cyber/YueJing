import SwiftUI

@main
@MainActor
struct YueJingApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if EPUBFontPickerUITestFixture.isRequested {
                EPUBFontPickerUITestFixture()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
