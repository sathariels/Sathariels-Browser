import Foundation
import WebKit

enum ReaderExtract {
    /// Image-heavy chapters (manga, manhwa) stay a vertical strip instead of an article.
    static func prefersImageStrip(imageCount: Int, textCharacters: Int) -> Bool {
        imageCount >= 4 && textCharacters < imageCount * 400
    }
}

struct ReaderPage: Equatable {
    struct Block: Equatable, Identifiable {
        enum Kind: Equatable { case text, image }
        var id: Int
        var kind: Kind
        var text: String
    }

    var title: String
    var blocks: [Block]
    var imageStrip: Bool
}

enum ReaderScript {
    static let source = """
    (function () {
      function abs(value) {
        if (!value) return '';
        try { return new URL(value, document.baseURI).href; } catch (e) { return ''; }
      }
      var images = [];
      var seen = {};
      var nodes = document.querySelectorAll('img');
      var cap = Math.min(nodes.length, 80);
      for (var i = 0; i < cap; i++) {
        var img = nodes[i];
        var src = abs(img.currentSrc || img.src || img.getAttribute('data-src') || '');
        var width = img.naturalWidth || img.width || 0;
        if (!src || seen[src] || width && width < 180) continue;
        seen[src] = true;
        images.push(src);
      }
      var text = '';
      try { text = (document.body && document.body.innerText) ? document.body.innerText : ''; } catch (e) {}
      var imageStrip = images.length >= 4 && text.length < images.length * 400;
      if (imageStrip) {
        return { title: document.title || '', imageStrip: true, blocks: images.map(function (src) { return { kind: 'image', text: src }; }) };
      }
      var best = null;
      var bestScore = 0;
      var candidates = document.querySelectorAll('article, main, [role="main"], .chapter, .entry-content, .post-content');
      if (!candidates.length) candidates = [document.body];
      for (var c = 0; c < candidates.length; c++) {
        var node = candidates[c];
        if (!node) continue;
        var score = 0;
        var paragraphs = node.querySelectorAll('p, h1, h2, h3, li, pre, blockquote');
        for (var p = 0; p < paragraphs.length && p < 400; p++) score += (paragraphs[p].innerText || '').length;
        if (score > bestScore) { bestScore = score; best = node; }
      }
      var blocks = [];
      var root = best || document.body;
      if (root) {
        var parts = root.querySelectorAll('p, h1, h2, h3, li, pre, blockquote, img');
        var limit = Math.min(parts.length, 240);
        for (var n = 0; n < limit; n++) {
          var el = parts[n];
          if (el.tagName === 'IMG') {
            var href = abs(el.currentSrc || el.src || '');
            if (href) blocks.push({ kind: 'image', text: href });
          } else {
            var line = (el.innerText || '').replace(/\\s+/g, ' ').trim();
            if (line.length > 1) blocks.push({ kind: 'text', text: line.slice(0, 2000) });
          }
          if (blocks.length >= 180) break;
        }
      }
      return { title: document.title || '', imageStrip: false, blocks: blocks };
    })()
    """

    static func page(from result: Any?) -> ReaderPage? {
        let object = result as? [String: Any]
        let title = (object?["title"] as? String) ?? ""
        let rawBlocks = object?["blocks"] as? [[String: Any]] ?? []
        var blocks: [ReaderPage.Block] = []
        blocks.reserveCapacity(min(rawBlocks.count, 180))
        for (index, item) in rawBlocks.prefix(180).enumerated() {
            let kind = (item["kind"] as? String) == "image" ? ReaderPage.Block.Kind.image : .text
            let text = String((item["text"] as? String ?? "").prefix(2000))
            if text.isEmpty { continue }
            blocks.append(ReaderPage.Block(id: index, kind: kind, text: text))
        }
        let images = blocks.filter { $0.kind == .image }.count
        let characters = blocks.filter { $0.kind == .text }.reduce(0) { $0 + $1.text.count }
        let strip = (object?["imageStrip"] as? Bool) ?? ReaderExtract.prefersImageStrip(imageCount: images, textCharacters: characters)
        guard !blocks.isEmpty else { return nil }
        return ReaderPage(title: title, blocks: blocks, imageStrip: strip)
    }
}

enum SessionStateStore {
    static let byteCap = 1_200_000

    static func write(id: UUID, data: Data) -> String? {
        guard !data.isEmpty, data.count <= byteCap else { return nil }
        let name = "states/\(id.uuidString).bin"
        guard let url = try? fileURL(name) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func read(_ name: String?) -> Data? {
        guard let name, let url = try? fileURL(name), FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= byteCap else { return nil }
        return data
    }

    static func data(from interactionState: Any?) -> Data? {
        if let data = interactionState as? Data { return data }
        if let data = interactionState as? NSData { return data as Data }
        return nil
    }

    private static func fileURL(_ name: String) throws -> URL? {
        guard name.hasPrefix("states/"), !name.contains(".."), !name.contains("//") else { return nil }
        return try JSONStore.url(name)
    }
}
