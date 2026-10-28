#if DEBUG
import SwiftUI

/// Reads the mounted shelf environment only in the isolated UI-test launch; no theme override or logging.
struct ReadingUITestSchemeProbe: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicType
    var body: some View {
        Text("UI测试书架").font(.caption2).padding(4).background(.thinMaterial)
            .accessibilityLabel("UI测试书架外观")
            .accessibilityIdentifier("ui.fixture.shelf.scheme")
            .accessibilityValue("\(scheme == .dark ? "dark" : "light")|\(dynamicType.isAccessibilitySize ? "accessibility" : "standard")")
            .allowsHitTesting(false)
    }
}
#endif
