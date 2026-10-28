import SwiftUI

struct UpdateSheet: View {
    @ObservedObject var center: AppUpdateCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UPDATE")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.amber)
            Text(center.offer.map { "Version \($0.version)" } ?? "Updates")
                .font(LumenTheme.title)
                .foregroundStyle(LumenTheme.text)
            Text(center.status)
                .font(LumenTheme.monoSmall)
                .foregroundStyle(center.failed ? LumenTheme.coral : LumenTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = center.offer?.notes, !notes.isEmpty {
                ScrollView {
                    Text(ReleaseNotes.plain(notes))
                        .font(LumenTheme.monoSmall)
                        .foregroundStyle(LumenTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
                .padding(8)
                .background(LumenTheme.bg)
                .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
            }
            if !center.log.isEmpty {
                ScrollView {
                    Text(center.log)
                        .font(LumenTheme.micro)
                        .foregroundStyle(LumenTheme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 80)
            }
            HStack(spacing: 8) {
                if center.offer != nil {
                    Button("Update now") { center.install() }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.amber))
                        .disabled(center.busy)
                    Button("Later") { center.later() }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
                    Button("Skip this version") { center.skip() }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
                }
                if center.failed || center.offer == nil {
                    Button("Open release page") { center.openReleasePage() }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.sky))
                    Button("Close") { center.later() }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(LumenTheme.bgRaised)
    }
}

enum ReleaseNotes {
    static func plain(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var text = String(line)
            if text.hasPrefix("### ") { text = String(text.dropFirst(4)) }
            else if text.hasPrefix("## ") { text = String(text.dropFirst(3)) }
            else if text.hasPrefix("# ") { text = String(text.dropFirst(2)) }
            if text.hasPrefix("- ") || text.hasPrefix("* ") {
                text = "• " + String(text.dropFirst(2))
            }
            return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        }.joined(separator: "\n")
    }
}
