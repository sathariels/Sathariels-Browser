import AppKit
import SwiftUI

struct JSONTreeView: View {
    @ObservedObject var tab: BrowserTab
    let document: JSONDocument
    @State private var pretty = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SectionLabel(title: "JSON", color: LumenTheme.sky)
                Spacer()
                Button(pretty ? "Raw" : "Tree") { pretty.toggle() }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.sky))
                Button("Reload page") { tab.showJSONAsPage() }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            if pretty {
                ScrollView {
                    JSONNodeView(value: document.value, path: "$")
                        .padding(8)
                }
            } else {
                ScrollView {
                    Text(document.raw)
                        .font(LumenTheme.monoSmall)
                        .foregroundStyle(LumenTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumenTheme.bg)
    }
}

struct JSONNodeView: View {
    let value: JSONValue
    let path: String
    @State private var open = false

    var body: some View {
        switch value {
        case .object(let pairs):
            branch(label: "{\(pairs.count)}", children: pairs.map { pair in
                (JSONValue.childPath(parent: path, key: pair.key), pair.key, pair.value)
            })
        case .array(let items):
            branch(label: "[\(items.count)]", children: items.enumerated().map { index, item in
                (JSONValue.indexPath(parent: path, index: index), String(index), item)
            })
        default:
            leaf
        }
    }

    private func branch(label: String, children: [(String, String, JSONValue)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(open ? "−" : "+") { open.toggle() }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.amber))
                Text(label)
                    .font(LumenTheme.monoSmall)
                    .foregroundStyle(LumenTheme.textDim)
                copyButtons
            }
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    let shown = children.prefix(200)
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, child in
                        HStack(alignment: .top, spacing: 6) {
                            Text(child.1)
                                .font(LumenTheme.monoSmall)
                                .foregroundStyle(LumenTheme.amber)
                            JSONNodeView(value: child.2, path: child.0)
                        }
                        .padding(.leading, 12)
                    }
                    if children.count > 200 {
                        Text("Showing 200 of \(children.count)")
                            .font(LumenTheme.micro)
                            .foregroundStyle(LumenTheme.textDim)
                    }
                }
            }
        }
    }

    private var leaf: some View {
        HStack(spacing: 6) {
            Text(leafText)
                .font(LumenTheme.monoSmall)
                .foregroundStyle(leafColor)
                .textSelection(.enabled)
            copyButtons
        }
    }

    private var copyButtons: some View {
        HStack(spacing: 4) {
            Button("Path") { copy(path) }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
            Button("Value") { copy(value.copyText) }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.teal))
        }
    }

    private var leafText: String {
        switch value {
        case .string(let text): return "\"\(text)\""
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        default: return ""
        }
    }

    private var leafColor: Color {
        switch value {
        case .string: return LumenTheme.teal
        case .number: return LumenTheme.sky
        case .bool: return LumenTheme.violet
        default: return LumenTheme.textDim
        }
    }

    private func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
