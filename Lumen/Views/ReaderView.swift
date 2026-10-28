import AppKit
import ImageIO
import SwiftUI

struct ReaderView: View {
    @ObservedObject var tab: BrowserTab
    let page: ReaderPage
    @State private var size: Double = 17
    @State private var column: Double = 680

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(page.imageStrip ? "IMAGES" : "READER")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.amber)
                Text(page.title)
                    .font(LumenTheme.monoSmall)
                    .foregroundStyle(LumenTheme.text)
                    .lineLimit(1)
                Spacer()
                Stepper(value: $size, in: 13...28, step: 1) {
                    Text("\(Int(size))")
                        .font(LumenTheme.micro)
                        .foregroundStyle(LumenTheme.textDim)
                        .frame(width: 24)
                }
                .frame(width: 90)
                Stepper(value: $column, in: 420...980, step: 40) {
                    Text("\(Int(column))")
                        .font(LumenTheme.micro)
                        .foregroundStyle(LumenTheme.textDim)
                        .frame(width: 36)
                }
                .frame(width: 110)
                Button("Close") { tab.reader = nil }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
            }
            .padding(8)
            .background(LumenTheme.bgRaised)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: page.imageStrip ? 0 : 12) {
                    ForEach(page.blocks) { block in
                        switch block.kind {
                        case .text:
                            Text(block.text)
                                .font(.system(size: size, weight: .regular, design: .default))
                                .foregroundStyle(LumenTheme.text)
                                .frame(maxWidth: column, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        case .image:
                            ReaderImage(urlString: block.text, width: page.imageStrip ? column : min(column, 720))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .background(LumenTheme.bg)
        }
    }
}

private struct ReaderImage: View {
    let urlString: String
    let width: Double
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: width)
            } else {
                Rectangle()
                    .fill(LumenTheme.bgRaised)
                    .frame(width: width, height: 48)
            }
        }
        .task(id: urlString) {
            image = await Self.load(urlString, maxPixel: Int(width * 2))
        }
    }

    private static func load(_ string: String, maxPixel: Int) async -> NSImage? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 12_000_000 else { return nil }
        return thumbnail(data, maxPixel: maxPixel)
    }

    private static func thumbnail(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
