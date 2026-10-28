import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var permissions = PermissionStore.shared
    @ObservedObject private var blocker = ContentBlocker.shared
    @State private var section = "General"
    @State private var keyDraft = ""
    @State private var keyStatus = APIKeyStore.isSet ? "Saved in the Keychain" : "Not set"
    @State private var accounts: [PasswordVault.Account] = []

    private let sections = ["General", "Memory", "Clipboard", "Passwords", "Sites", "Grok", "Blocker"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.self) { name in
                    Button(name) { section = name }
                        .buttonStyle(LumenButtonStyle(tint: section == name ? color(name) : LumenTheme.textDim))
                        .padding(.bottom, 2)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 140)
            .background(LumenTheme.bgRaised)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch section {
                    case "Memory": memory
                    case "Clipboard": clipboard
                    case "Passwords": passwords
                    case "Sites": sites
                    case "Grok": grok
                    case "Blocker": blockerSection
                    default: general
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 460)
        .background(LumenTheme.bg)
        .preferredColorScheme(.dark)
        .onChange(of: section) { _, value in
            if value == "Passwords" { accounts = PasswordVault.allAccounts() }
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "General", color: LumenTheme.amber)
            Picker("Search", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            TextField("Home page", text: $settings.homePage)
                .textFieldStyle(.plain)
                .font(LumenTheme.mono)
                .foregroundStyle(LumenTheme.text)
                .padding(6)
                .background(LumenTheme.field)
                .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
            Toggle("Restore tabs after quit or crash", isOn: $settings.restoreSession)
                .font(LumenTheme.monoSmall)
            Text("User agent: \(SafariUserAgent.current)")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.textDim)
                .textSelection(.enabled)
            Button("Use Lumen for http and https links") {
                try? NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
                try? NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https")
            }
            .buttonStyle(LumenButtonStyle(tint: LumenTheme.amber))
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Memory", color: LumenTheme.amber)
            Stepper(value: $settings.suspendMinutes, in: 1...180) {
                Text("Suspend idle tabs after \(settings.suspendMinutes) min")
                    .font(LumenTheme.monoSmall)
                    .foregroundStyle(LumenTheme.text)
            }
            Text("Background tabs, including the split pane you are not using, drop their WKWebView after they sit idle. A memory warning suspends everything except the focused pane. New tabs stay native until you navigate.")
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.textDim)
        }
    }

    private var clipboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Clipboard", color: LumenTheme.teal)
            Toggle("Capture clipboard history", isOn: $settings.clipboardCapture)
                .font(LumenTheme.monoSmall)
            Text("Items marked concealed or transient (password managers do this) are ignored. Images are stored as small thumbnails. Capture pauses while a private window is key.")
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.textDim)
        }
    }

    private var passwords: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Passwords", color: LumenTheme.lime)
            Text("WKWebView cannot read Safari's iCloud Passwords for arbitrary sites. Lumen saves logins you confirm into the Keychain as internet passwords. They are never written to JSON or logs. Synchronizable items can join iCloud Keychain when that is turned on.")
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.textDim)
            if accounts.isEmpty {
                Text("No Lumen passwords saved.")
                    .font(LumenTheme.monoSmall)
                    .foregroundStyle(LumenTheme.text)
            }
            ForEach(accounts) { account in
                HStack {
                    Text(account.host).font(LumenTheme.monoSmall).foregroundStyle(LumenTheme.text)
                    Text(account.username).font(LumenTheme.micro).foregroundStyle(LumenTheme.textDim)
                    Spacer()
                    Button("Delete") {
                        PasswordVault.delete(host: account.host, username: account.username)
                        accounts = PasswordVault.allAccounts()
                    }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                }
            }
        }
    }

    private var sites: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Sites", color: LumenTheme.sky)
            if permissions.sites.isEmpty {
                Text("Permissions appear here after a site asks, or after you set them from the address bar.")
                    .font(LumenTheme.monoSmall)
                    .foregroundStyle(LumenTheme.textDim)
            }
            ForEach(permissions.sites) { site in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(site.host).font(LumenTheme.monoSmall).foregroundStyle(LumenTheme.text)
                        Spacer()
                        Button("Remove") { permissions.remove(host: site.host) }
                            .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                    }
                    Text(PermissionKind.allCases.map { "\($0.label) \(site.choice(for: $0).rawValue)" }.joined(separator: "  ·  "))
                        .font(LumenTheme.micro)
                        .foregroundStyle(LumenTheme.textDim)
                }
                .padding(.bottom, 6)
            }
            if !permissions.sites.isEmpty {
                Button("Reset all sites") { permissions.removeAll() }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
            }
        }
    }

    private var grok: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Grok", color: LumenTheme.violet)
            Text(keyStatus).font(LumenTheme.micro).foregroundStyle(LumenTheme.teal)
            SecureField("xAI API key", text: $keyDraft)
                .textFieldStyle(.plain)
                .font(LumenTheme.mono)
                .foregroundStyle(LumenTheme.text)
                .padding(6)
                .background(LumenTheme.field)
                .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
            HStack {
                Button("Save key") {
                    do {
                        try APIKeyStore.save(keyDraft)
                        keyDraft = ""
                        keyStatus = "Saved in the Keychain"
                    } catch {
                        keyStatus = "Keychain rejected the save (\(error))"
                    }
                }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.violet))
                Button("Delete key") {
                    APIKeyStore.clear()
                    keyDraft = ""
                    keyStatus = "Not set"
                }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
            }
            TextField("Model", text: $settings.grokModel)
                .textFieldStyle(.plain)
                .font(LumenTheme.mono)
                .foregroundStyle(LumenTheme.text)
                .padding(6)
                .background(LumenTheme.field)
                .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
            Text("Chat completions go to https://api.x.ai/v1. Default model is grok-4.7. The key is not stored in the repo or in UserDefaults.")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.textDim)
            TextField("Grok Bot URL", text: $settings.grokBotURL)
                .textFieldStyle(.plain)
                .font(LumenTheme.mono)
                .foregroundStyle(LumenTheme.text)
                .padding(6)
                .background(LumenTheme.field)
                .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
            Text("The sidebar opens this URL (default grokbot://). Send Page copies the title, URL, and selection, then launches it. There is no Grok Bot chat API.")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.textDim)
        }
    }

    private var blockerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Blocker", color: LumenTheme.violet)
            Toggle("Block ads and trackers", isOn: $settings.contentBlocking)
                .font(LumenTheme.monoSmall)
            Text(blocker.phaseLabel)
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.text)
            Text("A small bundled rule list. Sign-in pages on accounts.google.com are excluded. This is not a substitute for a full filter list.")
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.textDim)
        }
    }

    private func color(_ name: String) -> Color {
        switch name {
        case "Clipboard": return LumenTheme.teal
        case "Passwords": return LumenTheme.lime
        case "Sites": return LumenTheme.sky
        case "Grok", "Blocker": return LumenTheme.violet
        default: return LumenTheme.amber
        }
    }
}
