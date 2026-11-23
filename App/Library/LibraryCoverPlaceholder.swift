import SwiftUI

/// A fine-press clothbound typographic placeholder, not an extracted or downloaded cover.
@MainActor
struct LibraryCoverPlaceholder: View {
    let title: String
    let appearance: LibraryAppearance
    var formatLabel: String? = nil
    var size: CGSize = CGSize(width: LibraryAppearance.coverWidth, height: LibraryAppearance.coverHeight)

    private struct ClothTone {
        let lightFill: UInt32
        let lightInk: UInt32
        let lightAccent: UInt32
        let darkFill: UInt32
        let darkInk: UInt32
        let darkAccent: UInt32
    }

    private static let clothTones: [ClothTone] = [
        // 松烟青 Pine Celadon
        ClothTone(lightFill: 0xD7E2DA, lightInk: 0x1F352B, lightAccent: 0x356854,
                  darkFill: 0x263830, darkInk: 0xDCEAE2, darkAccent: 0x86C0A8),
        // 黛青 Indigo Slate
        ClothTone(lightFill: 0xD8E1EB, lightInk: 0x1F2E40, lightAccent: 0x325A82,
                  darkFill: 0x253242, darkInk: 0xDCE6F2, darkAccent: 0x8BB8DF),
        // 赭石 Terracotta Clay
        ClothTone(lightFill: 0xEADCD2, lightInk: 0x42261C, lightAccent: 0x9F513D,
                  darkFill: 0x3D2B25, darkInk: 0xF0DFD5, darkAccent: 0xD88B76),
        // 琥珀 Warm Ochre
        ClothTone(lightFill: 0xEAE2CC, lightInk: 0x3D3019, lightAccent: 0x8F6D31,
                  darkFill: 0x3B3424, darkInk: 0xEFE7D1, darkAccent: 0xCFAF6C),
        // 暮梅 Muted Plum
        ClothTone(lightFill: 0xE5DAE2, lightInk: 0x392434, lightAccent: 0x7A4B6E,
                  darkFill: 0x362834, darkInk: 0xEBE0E8, darkAccent: 0xC494B8),
        // 苔石 Moss Stone
        ClothTone(lightFill: 0xE2E0D5, lightInk: 0x2E3127, lightAccent: 0x5F684A,
                  darkFill: 0x30332A, darkInk: 0xE7E6DC, darkAccent: 0xAAB491)
    ]

    private var tone: ClothTone {
        let seed = title.unicodeScalars.reduce(into: 0) { acc, scalar in
            acc = (acc &* 31) &+ Int(scalar.value)
        }
        let index = abs(seed) % Self.clothTones.count
        return Self.clothTones[index]
    }

    private var fillColor: Color {
        rgb(appearance.isDarkSurface ? tone.darkFill : tone.lightFill)
    }

    private var inkColor: Color {
        rgb(appearance.isDarkSurface ? tone.darkInk : tone.lightInk)
    }

    private var accentColor: Color {
        rgb(appearance.isDarkSurface ? tone.darkAccent : tone.lightAccent)
    }

    private var cornerRadius: CGFloat {
        max(6, min(11, size.width * 0.13))
    }

    private var leadingGlyph: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.first ?? "阅")
    }

    var body: some View {
        let isLarge = size.width >= 72
        ZStack(alignment: .leading) {
            // Clothbound base
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [fillColor, fillColor.opacity(appearance.isDarkSurface ? 0.88 : 0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Subtle book spine band & crease
            HStack(spacing: 0) {
                Rectangle()
                    .fill(accentColor.opacity(appearance.isDarkSurface ? 0.24 : 0.16))
                    .frame(width: max(5, size.width * 0.10))
                Rectangle()
                    .fill(inkColor.opacity(0.14))
                    .frame(width: 0.75)
                Rectangle()
                    .fill(Color.white.opacity(appearance.isDarkSurface ? 0.08 : 0.45))
                    .frame(width: 0.75)
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // Delicate inner binding frame
            RoundedRectangle(cornerRadius: max(3, cornerRadius - 3), style: .continuous)
                .strokeBorder(accentColor.opacity(0.28), lineWidth: 0.6)
                .padding(.top, isLarge ? 7 : 5)
                .padding(.bottom, isLarge ? 7 : 5)
                .padding(.trailing, isLarge ? 6 : 4)
                .padding(.leading, max(9, size.width * 0.16))

            // Traditional title cartouche with serif centerpiece glyph
            VStack(spacing: isLarge ? 6 : 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(appearance.surface.opacity(appearance.isDarkSurface ? 0.22 : 0.72))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.32), lineWidth: 0.5)
                    Text(leadingGlyph)
                        // Decorative artwork glyph; the real book title uses Dynamic Type in the row/card.
                        .font(.system(size: max(18, size.width * 0.34), weight: .semibold, design: .serif))
                        .foregroundStyle(inkColor)
                }
                .frame(width: size.width * 0.50, height: size.height * 0.46)

                if let formatLabel, isLarge {
                    Text(formatLabel)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(accentColor.opacity(0.12), in: Capsule())
                } else {
                    Rectangle()
                        .fill(accentColor.opacity(0.38))
                        .frame(width: size.width * 0.28, height: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, size.width * 0.08)

            // Paper fore-edge highlight on trailing edge
            HStack {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Color.white.opacity(appearance.isDarkSurface ? 0.08 : 0.55))
                    .frame(width: 1.2)
                    .padding(.vertical, 3)
            }

            // Crisp outer hairline border
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(inkColor.opacity(appearance.isDarkSurface ? 0.24 : 0.14), lineWidth: 0.6)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: appearance.shadow, radius: isLarge ? 8 : 4, x: 0, y: isLarge ? 4 : 2)
        .accessibilityHidden(true)
    }

    private func rgb(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}
