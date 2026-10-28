import AppKit
import SwiftUI

/// Blocky dark chrome. Square controls, 1px borders, a short accent list.
enum LumenTheme {
    static let bg = Color(red: 0.078, green: 0.086, blue: 0.098)
    static let bgRaised = Color(red: 0.118, green: 0.129, blue: 0.149)
    static let field = Color(red: 0.067, green: 0.071, blue: 0.082)
    static let border = Color(red: 0.275, green: 0.298, blue: 0.345)
    static let text = Color(red: 0.890, green: 0.898, blue: 0.855)
    static let textDim = Color(red: 0.557, green: 0.580, blue: 0.557)

    static let amber = Color(red: 0.910, green: 0.620, blue: 0.180)
    static let teal = Color(red: 0.180, green: 0.760, blue: 0.670)
    static let coral = Color(red: 0.910, green: 0.345, blue: 0.310)
    static let violet = Color(red: 0.620, green: 0.510, blue: 0.960)
    static let lime = Color(red: 0.640, green: 0.780, blue: 0.280)
    static let sky = Color(red: 0.310, green: 0.640, blue: 0.910)

    static let tabPalette: [Color] = [amber, teal, coral, violet, lime, sky]

    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let micro = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let title = Font.system(size: 13, weight: .medium, design: .default)

    static func tabColor(_ index: Int) -> Color {
        tabPalette[abs(index) % tabPalette.count]
    }

    static var windowBackground: NSColor {
        NSColor(srgbRed: 0.078, green: 0.086, blue: 0.098, alpha: 1)
    }
}

struct LumenButtonStyle: ButtonStyle {
    var tint: Color = LumenTheme.amber

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LumenTheme.monoSmall)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(configuration.isPressed ? tint.opacity(0.22) : Color.clear)
            .overlay(Rectangle().strokeBorder(tint.opacity(0.9), lineWidth: 1))
    }
}

struct SectionLabel: View {
    var title: String
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 8, height: 8)
            Text(title.uppercased())
                .font(LumenTheme.micro)
                .foregroundStyle(color)
                .tracking(1.2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
