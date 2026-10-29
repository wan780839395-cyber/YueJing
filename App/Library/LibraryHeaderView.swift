import SwiftUI

@MainActor
struct LibraryHeaderView: View {
    let bookCount: Int
    let appearance: LibraryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("书架")
                    .font(LibraryAppearance.titleFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("\(bookCount) 本")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 8) {
                // The open gate/book mark is decorative, not a new action.
                Path { path in
                    path.move(to: CGPoint(x: 3, y: 14))
                    path.addLine(to: CGPoint(x: 3, y: 5))
                    path.addQuadCurve(to: CGPoint(x: 5, y: 3), control: CGPoint(x: 3, y: 3))
                    path.addLine(to: CGPoint(x: 7, y: 3))
                    path.move(to: CGPoint(x: 11, y: 3))
                    path.addLine(to: CGPoint(x: 13, y: 3))
                    path.addQuadCurve(to: CGPoint(x: 15, y: 5), control: CGPoint(x: 15, y: 3))
                    path.addLine(to: CGPoint(x: 15, y: 14))
                    path.move(to: CGPoint(x: 6, y: 7))
                    path.addLines([CGPoint(x: 8, y: 7), CGPoint(x: 9, y: 8),
                                   CGPoint(x: 10, y: 7), CGPoint(x: 12, y: 7),
                                   CGPoint(x: 12, y: 14), CGPoint(x: 10, y: 14),
                                   CGPoint(x: 9, y: 15), CGPoint(x: 8, y: 14),
                                   CGPoint(x: 6, y: 14), CGPoint(x: 6, y: 7)])
                    path.move(to: CGPoint(x: 9, y: 8))
                    path.addLine(to: CGPoint(x: 9, y: 15))
                }
                .stroke(appearance.accent, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                Text("开卷，自有一境。")
                    .font(.footnote).foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(appearance.edge).frame(height: 0.5)
                .overlay(alignment: .leading) {
                    Capsule().fill(appearance.accent).frame(width: 28, height: 3)
                }
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .foregroundStyle(appearance.foreground)
        .padding(.top, 8).padding(.bottom, 2)
    }
}
