import SwiftUI

struct StartPageView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var blocker = ContentBlocker.shared
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @FocusState private var focused: Bool
    @State private var services: [(name: String, port: UInt16, color: Color, open: Bool?)] = [
        ("Web app", 3000, Color(red: 98 / 255, green: 165 / 255, blue: 116 / 255), nil),
        ("Postgres", 5432, Color(red: 209 / 255, green: 163 / 255, blue: 76 / 255), nil),
        ("Redis", 6379, Color(red: 102 / 255, green: 141 / 255, blue: 161 / 255), nil)
    ]
    @State private var scanning = false

    var body: some View {
        ZStack {
            LumenTheme.workspace
            WorkspaceGrid()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    search
                    moduleGrid
                }
                .frame(maxWidth: 1120)
                .padding(.horizontal, 24)
                .padding(.top, 30)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LumenTheme.markLeaf)
                        .frame(width: 29, height: 29)
                        .background(Color(red: 41 / 255, green: 70 / 255, blue: 56 / 255))
                    Text("Sathariels")
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumenTheme.ink)
                    Text("DEV")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color(red: 65 / 255, green: 99 / 255, blue: 79 / 255))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(red: 219 / 255, green: 230 / 255, blue: 220 / 255))
                }
                Text(session.isPrivate ? "Private window. Nothing here is saved." : "\(greeting). All systems operational.")
                    .font(.system(size: 12))
                    .foregroundStyle(LumenTheme.muted)
            }
            Spacer()
            Button { openSettings() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                    Text("Customize workspace")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 52 / 255, green: 84 / 255, blue: 68 / 255))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color.white)
                .overlay(Rectangle().strokeBorder(LumenTheme.moduleLine, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var search: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LumenTheme.muted)
            TextField("Search web, docs, repos, or type a command...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(LumenTheme.ink)
                .focused($focused)
                .onSubmit { go() }
            Text("⌘K")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(LumenTheme.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(red: 241 / 255, green: 243 / 255, blue: 239 / 255))
                .overlay(Rectangle().strokeBorder(LumenTheme.ink.opacity(0.12), lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .frame(maxWidth: 760, alignment: .leading)
        .background(Color.white)
        .overlay(Rectangle().strokeBorder(focused ? Color(red: 57 / 255, green: 116 / 255, blue: 84 / 255) : Color(red: 174 / 255, green: 183 / 255, blue: 177 / 255), lineWidth: 1))
        .padding(.vertical, 22)
        .background {
            Button("Focus search") { focused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private var moduleGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    projects
                    terminalCard
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    servicesCard
                    resources
                }
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 14) {
                projects
                servicesCard
                terminalCard
                resources
            }
        }
    }

    private var projects: some View {
        module(kicker: "Projects", title: "Continue building", trailing: AnyView(
            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(LumenTheme.ink)
        )) {
            if recent.isEmpty {
                projectLink(icon: "leaf.fill", tint: Color(red: 86 / 255, green: 123 / 255, blue: 103 / 255), title: "GitHub", detail: "github.com", status: "Open", live: false) {
                    open("https://github.com")
                }
                projectLink(icon: "terminal", tint: Color(red: 55 / 255, green: 65 / 255, blue: 60 / 255), title: "Apple docs", detail: "developer.apple.com", status: "Open", live: false) {
                    open("https://developer.apple.com")
                }
                projectLink(icon: "safari", tint: Color(red: 156 / 255, green: 115 / 255, blue: 95 / 255), title: "Localhost", detail: "127.0.0.1:3000", status: "Open", live: false) {
                    open("http://127.0.0.1:3000")
                }
            } else {
                ForEach(recent) { entry in
                    projectLink(icon: "globe", tint: LumenTheme.accent, title: entry.title, detail: entry.host, status: "Recent", live: true) {
                        open(entry.url)
                    }
                }
            }
        }
    }

    private var servicesCard: some View {
        module(kicker: "Environment", title: "Local services", trailing: AnyView(
            Button {
                scanServices()
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(scanning ? LumenTheme.muted : Color(red: 99 / 255, green: 168 / 255, blue: 113 / 255)).frame(width: 6, height: 6)
                    Text(scanning ? "Scanning" : "Scan")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 77 / 255, green: 120 / 255, blue: 91 / 255))
                }
            }
            .buttonStyle(.plain)
            .disabled(scanning)
        )) {
            ForEach(services, id: \.port) { service in
                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(service.open == nil ? service.color.opacity(0.35) : (service.open == true ? service.color : LumenTheme.muted)).frame(width: 7, height: 7)
                        Text(service.name)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LumenTheme.ink)
                    }
                    Spacer()
                    Text(":\(service.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LumenTheme.muted)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture { open("http://127.0.0.1:\(service.port)") }
                Rectangle().fill(LumenTheme.ink.opacity(0.08)).frame(height: 1)
            }
            Button { open("http://127.0.0.1:3000") } label: {
                HStack {
                    Text("Open localhost")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(LumenTheme.accent)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
    }

    private var terminalCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 196 / 255, green: 109 / 255, blue: 96 / 255)).frame(width: 7, height: 7)
                    Circle().fill(Color(red: 200 / 255, green: 163 / 255, blue: 84 / 255)).frame(width: 7, height: 7)
                    Circle().fill(Color(red: 101 / 255, green: 112 / 255, blue: 105 / 255)).frame(width: 7, height: 7)
                }
                Spacer()
                Text("sathariels")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 142 / 255, green: 155 / 255, blue: 148 / 255))
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color(red: 154 / 255, green: 165 / 255, blue: 159 / 255))
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
            VStack(alignment: .leading, spacing: 2) {
                prompt("tabs \(session.tabs.count)")
                prompt(session.isPrivate ? "private window" : "webkit \(session.measuredWebKit > 0 ? MemoryFormat.megabytes(session.measuredWebKit) : "idle")")
                prompt("blocker \(blocker.phaseLabel)")
                HStack(spacing: 6) {
                    Text("➜")
                        .foregroundStyle(Color(red: 230 / 255, green: 189 / 255, blue: 100 / 255))
                    Rectangle()
                        .fill(Color(red: 127 / 255, green: 167 / 255, blue: 142 / 255))
                        .frame(width: 7, height: 12)
                }
                .font(.system(size: 12, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(LumenTheme.terminal)
        .overlay(Rectangle().strokeBorder(Color(red: 21 / 255, green: 26 / 255, blue: 23 / 255), lineWidth: 1))
    }

    private var resources: some View {
        module(kicker: "Pinned", title: "Developer resources", trailing: AnyView(EmptyView())) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                resource("R", "React", "Documentation", "https://react.dev")
                resource("TS", "TypeScript", "Handbook", "https://www.typescriptlang.org/docs/")
                resource("GH", "GitHub", "Repositories", "https://github.com")
                resource("F", "Figma", "Design files", "https://www.figma.com")
            }
        }
    }

    private func module<Content: View>(kicker: String, title: String, trailing: AnyView, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kicker.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Color(red: 138 / 255, green: 148 / 255, blue: 142 / 255))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumenTheme.ink)
                }
                Spacer()
                trailing
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .overlay(alignment: .bottom) { Rectangle().fill(LumenTheme.ink.opacity(0.1)).frame(height: 1) }
            content()
        }
        .background(LumenTheme.paper.opacity(0.95))
        .overlay(Rectangle().strokeBorder(LumenTheme.moduleLine, lineWidth: 1))
    }

    private func projectLink(icon: String, tint: Color, title: String, detail: String, status: String, live: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LumenTheme.ink)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LumenTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
                Text(status)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(live ? Color(red: 61 / 255, green: 107 / 255, blue: 80 / 255) : LumenTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(live ? Color(red: 220 / 255, green: 235 / 255, blue: 221 / 255) : Color(red: 237 / 255, green: 240 / 255, blue: 237 / 255))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumenTheme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(LumenTheme.ink.opacity(0.08)).frame(height: 1) }
    }

    private func resource(_ mark: String, _ title: String, _ detail: String, _ url: String) -> some View {
        Button { open(url) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(mark)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 73 / 255, green: 102 / 255, blue: 86 / 255))
                    .frame(width: 24, height: 24)
                    .background(Color(red: 224 / 255, green: 233 / 255, blue: 224 / 255))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LumenTheme.ink)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LumenTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .buttonStyle(.plain)
    }

    private func prompt(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text("➜")
                .foregroundStyle(Color(red: 230 / 255, green: 189 / 255, blue: 100 / 255))
            Text(text)
                .foregroundStyle(Color(red: 223 / 255, green: 231 / 255, blue: 225 / 255))
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var recent: [HistoryEntry] {
        Array(history.entries.sorted { $0.lastVisit > $1.lastVisit }.prefix(3))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private func go() {
        guard let url = AddressResolver.resolve(query, engine: settings.searchEngine, shortcuts: settings.keywordShortcuts) else { return }
        session.select(tab.id)
        session.navigateFocused(to: url)
    }

    private func open(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        session.select(tab.id)
        session.navigateFocused(to: url)
    }

    private func scanServices() {
        guard !scanning else { return }
        scanning = true
        let ports = services.map(\.port)
        Task {
            var found: [UInt16: Bool] = [:]
            for port in ports {
                found[port] = await LocalhostScanner.probe(port)
            }
            await MainActor.run {
                services = services.map { item in
                    (item.name, item.port, item.color, found[item.port] ?? false)
                }
                scanning = false
            }
        }
    }
}

private struct WorkspaceGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 24
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(Color(red: 42 / 255, green: 57 / 255, blue: 48 / 255).opacity(0.06)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
