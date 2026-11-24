import CoreText
import SwiftUI

/// Only the sample text uses the selected face; controls and status labels keep Dynamic Type.
struct ReaderSpecimenText: View {
    var text = "晚风翻过书页，\n故事在此刻继续。Aa 123"
    let face: CGFont?
    let size: CGFloat
    let lineSpacing: CGFloat

    var body: some View {
        Text(verbatim: text)
            .font(face.map { Font(CTFontCreateWithGraphicsFont($0, size, nil, nil)) }
                  ?? .custom("PingFangSC-Regular", fixedSize: size))
            .lineSpacing(lineSpacing)
    }
}
