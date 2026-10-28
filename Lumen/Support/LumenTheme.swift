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
        NSColor(srgbRed: 29 / 255, green: 34 / 255, blue: 31 / 255, alpha: 1)
    }

    /// Sharp developer chrome from the UI reference. Square, dark window, light workspace.
    static let strip = Color(red: 29 / 255, green: 34 / 255, blue: 31 / 255)
    static let tabIdle = Color(red: 37 / 255, green: 43 / 255, blue: 39 / 255)
    static let tabLine = Color(red: 48 / 255, green: 55 / 255, blue: 51 / 255)
    static let toolbar = Color(red: 48 / 255, green: 54 / 255, blue: 50 / 255)
    static let activeText = Color(red: 230 / 255, green: 235 / 255, blue: 231 / 255)
    static let tabText = Color(red: 157 / 255, green: 167 / 255, blue: 160 / 255)
    static let accent = Color(red: 85 / 255, green: 167 / 255, blue: 120 / 255)
    static let mark = Color(red: 53 / 255, green: 71 / 255, blue: 61 / 255)
    static let markLeaf = Color(red: 141 / 255, green: 196 / 255, blue: 163 / 255)
    static let omnibox = Color(red: 37 / 255, green: 42 / 255, blue: 39 / 255)
    static let omniboxBorder = Color(red: 71 / 255, green: 80 / 255, blue: 73 / 255)
    static let omniboxFocus = Color(red: 94 / 255, green: 170 / 255, blue: 125 / 255)
    static let omniboxText = Color(red: 225 / 255, green: 231 / 255, blue: 227 / 255)
    static let omniboxMuted = Color(red: 152 / 255, green: 163 / 255, blue: 156 / 255)
    static let profile = Color(red: 53 / 255, green: 73 / 255, blue: 62 / 255)
    static let profileBorder = Color(red: 96 / 255, green: 129 / 255, blue: 109 / 255)
    static let profileText = Color(red: 185 / 255, green: 215 / 255, blue: 197 / 255)
    static let bookmarkBar = Color(red: 232 / 255, green: 235 / 255, blue: 232 / 255)
    static let bookmarkText = Color(red: 89 / 255, green: 102 / 255, blue: 95 / 255)
    static let workspace = Color(red: 238 / 255, green: 241 / 255, blue: 237 / 255)
    static let ink = Color(red: 45 / 255, green: 57 / 255, blue: 51 / 255)
    static let muted = Color(red: 124 / 255, green: 136 / 255, blue: 129 / 255)
    static let paper = Color(red: 250 / 255, green: 251 / 255, blue: 249 / 255)
    static let moduleLine = Color(red: 184 / 255, green: 192 / 255, blue: 186 / 255)
    static let terminal = Color(red: 32 / 255, green: 37 / 255, blue: 34 / 255)
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
