import SwiftUI

/// Management-page roles follow the system environment, never reader preferences.
@MainActor
struct LibraryAppearance {
    let colorScheme: ColorScheme

    static let horizontalInset: CGFloat = 22
    static let minimumControlHeight: CGFloat = 44
    static let coverWidth: CGFloat = 44
    static let coverHeight: CGFloat = 59
    static let entryCornerRadius: CGFloat = 15

    static var titleFont: Font { .system(.largeTitle, design: .serif).weight(.medium) }
    static var bookTitleFont: Font { .system(.title3, design: .serif).weight(.medium) }

    var page: Color {
        colorScheme == .dark ? rgb(26, 33, 30) : rgb(243, 245, 241)
    }
    var surface: Color {
        colorScheme == .dark ? rgb(42, 52, 45) : rgb(252, 253, 249)
    }
    var foreground: Color {
        colorScheme == .dark ? rgb(220, 227, 215) : rgb(53, 64, 56)
    }
    var secondary: Color {
        colorScheme == .dark ? rgb(170, 184, 168) : rgb(89, 102, 91)
    }
    var edge: Color {
        colorScheme == .dark ? rgb(58, 71, 61) : rgb(223, 229, 219)
    }
    var accent: Color {
        colorScheme == .dark ? rgb(212, 172, 144) : rgb(139, 91, 76)
    }
    var coverSurface: Color {
        colorScheme == .dark ? rgb(53, 70, 56) : rgb(220, 230, 216)
    }

    private func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1)
    }
}
