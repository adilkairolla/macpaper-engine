import AppKit

/// The format reference, ready to paste into an AI chat — optionally with one wallpaper's manifest and shaders.
enum AIGuide {
    static var referenceURL: URL? {
        Bundle.main.url(forResource: "FORMAT", withExtension: "md")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../FORMAT.md").standardizedFileURL
    }

    static func text(for wallpaper: Wallpaper?) -> String {
        var out = referenceURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        out += "\n\n## Built-in effect shaders you can copy\n\n"
        out += EffectCatalog.shaders.map { "- `\($0.id)`: \($0.summary)" }.joined(separator: "\n")
        guard let wallpaper else { return out }
        out += "\n\n---\n\n# The wallpaper I'm working on: \(wallpaper.title)\n\nPackage folder: `\(wallpaper.url.path)`\n\n"
        if let manifest = try? String(contentsOf: wallpaper.url.appendingPathComponent(Manifest.fileName), encoding: .utf8) {
            out += "## manifest.json\n\n```json\n\(manifest)\n```\n"
        }
        let shaders = Set(wallpaper.manifest.layers.compactMap { $0["type"]?.string == "shader" ? $0["src"]?.string : nil })
        for path in shaders.sorted() {
            if let url = wallpaper.file(path), let src = try? String(contentsOf: url, encoding: .utf8) {
                out += "\n## \(path)\n\n```metal\n\(src)\n```\n"
            }
        }
        return out
    }

    static func copy(for wallpaper: Wallpaper?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: wallpaper), forType: .string)
    }

    static func openReference() {
        if let url = referenceURL { NSWorkspace.shared.open(url) }
    }
}
