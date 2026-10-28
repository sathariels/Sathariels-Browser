import SwiftUI

struct SitePermissionsEditor: View {
    let host: String
    @ObservedObject var store: PermissionStore
    var onAutoplayChange: () -> Void = {}

    var body: some View {
        let site = store.site(for: host)
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: host, color: LumenTheme.sky)
            ForEach(PermissionKind.allCases) { kind in
                HStack(spacing: 8) {
                    Text(kind.label)
                        .font(LumenTheme.monoSmall)
                        .foregroundStyle(LumenTheme.text)
                        .frame(width: 110, alignment: .leading)
                    ForEach([PermissionChoice.allow, .ask, .deny], id: \.self) { choice in
                        Button(choice.rawValue) {
                            let previous = site.choice(for: kind)
                            store.set(host: host, kind: kind, choice: choice)
                            if kind == .autoplay && previous != choice { onAutoplayChange() }
                        }
                        .buttonStyle(LumenButtonStyle(tint: site.choice(for: kind) == choice ? color(choice) : LumenTheme.textDim))
                    }
                    Spacer(minLength: 0)
                }
            }
            Text(store.persistent ? "Remembered on this Mac." : "Private window. Choices are forgotten when it closes.")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.textDim)
        }
        .padding(8)
        .background(LumenTheme.bgRaised)
        .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
    }

    private func color(_ choice: PermissionChoice) -> Color {
        switch choice {
        case .allow: return LumenTheme.lime
        case .ask: return LumenTheme.amber
        case .deny: return LumenTheme.coral
        }
    }
}
