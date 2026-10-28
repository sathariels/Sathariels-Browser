import AppKit
import SwiftUI

/// Black surfaces and the X blue accent.
enum LumenTheme {
    static let bg = Color(red: 0 / 255, green: 0 / 255, blue: 0 / 255)
    static let bgRaised = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    static let field = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let border = Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255)
    static let text = Color(red: 235 / 255, green: 235 / 255, blue: 235 / 255)
    static let textDim = Color(red: 150 / 255, green: 150 / 255, blue: 150 / 255)

    static let amber = Color(red: 191 / 255, green: 178 / 255, blue: 145 / 255)
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
        NSColor(srgbRed: 0.03, green: 0.03, blue: 0.03, alpha: 1)
    }

    /// Shared surfaces keep native panels and the start page in the same dark palette.
    static let strip = Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    static let tabIdle = Color(red: 16 / 255, green: 16 / 255, blue: 16 / 255)
    static let tabLine = Color(red: 36 / 255, green: 36 / 255, blue: 36 / 255)
    static let toolbar = Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)
    static let activeText = Color(red: 230 / 255, green: 235 / 255, blue: 231 / 255)
    static let tabText = Color(red: 157 / 255, green: 167 / 255, blue: 160 / 255)
    /// Twitter/X blue. Text that sits on this fill uses `accentOn` (near-black); white is about 3:1 here.
    static let accent = Color(red: 29 / 255, green: 155 / 255, blue: 240 / 255)
    static let accentPressed = Color(red: 26 / 255, green: 140 / 255, blue: 216 / 255)
    static let accentFill = accent.opacity(0.14)
    static let accentOn = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    static let mark = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let markLeaf = Color(red: 183 / 255, green: 192 / 255, blue: 186 / 255)
    static let omnibox = Color(red: 22 / 255, green: 22 / 255, blue: 22 / 255)
    static let omniboxBorder = Color(red: 47 / 255, green: 47 / 255, blue: 47 / 255)
    static let omniboxFocus = accent
    static let omniboxText = Color(red: 235 / 255, green: 235 / 255, blue: 235 / 255)
    static let omniboxMuted = Color(red: 150 / 255, green: 150 / 255, blue: 150 / 255)
    static let profile = Color(red: 22 / 255, green: 22 / 255, blue: 22 / 255)
    static let profileBorder = Color(red: 96 / 255, green: 129 / 255, blue: 109 / 255)
    static let profileText = Color(red: 210 / 255, green: 210 / 255, blue: 210 / 255)
    static let bookmarkBar = Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    static let bookmarkText = Color(red: 155 / 255, green: 155 / 255, blue: 155 / 255)
    static let workspace = Color(red: 0 / 255, green: 0 / 255, blue: 0 / 255)
    static let ink = Color(red: 232 / 255, green: 232 / 255, blue: 232 / 255)
    static let muted = Color(red: 147 / 255, green: 147 / 255, blue: 147 / 255)
    static let paper = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    static let moduleLine = Color(red: 39 / 255, green: 39 / 255, blue: 39 / 255)
    static let terminal = Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255)
}

struct LumenButtonStyle: ButtonStyle {
    var tint: Color = LumenTheme.amber
    /// Hover and press use the darker accent. Leave off for the other palette colors.
    var accent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LumenButtonBody(configuration: configuration, tint: tint, accent: accent)
    }
}

private struct LumenButtonBody: View {
    let configuration: ButtonStyleConfiguration
    var tint: Color
    var accent: Bool
    @State private var hover = false

    var body: some View {
        let hot = accent && (hover || configuration.isPressed)
        configuration.label
            .font(LumenTheme.monoSmall)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(hot ? LumenTheme.accentPressed : tint)
            .background(hot ? LumenTheme.accentPressed.opacity(0.18) : (configuration.isPressed ? tint.opacity(0.22) : tint.opacity(0.07)))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder((hot ? LumenTheme.accentPressed : tint).opacity(0.25), lineWidth: 1))
            .onHover { hover = $0 }
    }
}

struct AccentFillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentFillBody(configuration: configuration)
    }
}

private struct AccentFillBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(LumenTheme.accentOn)
            .background((hover || configuration.isPressed) ? LumenTheme.accentPressed : LumenTheme.accent)
            .onHover { hover = $0 }
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
