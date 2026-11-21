import AppKit
import PocketKit
import SwiftUI

/// `FM1Pocket --ui-snapshot CATALOGUE_DIR OUT_DIR SHOT...`: the app as people use it, reading the catalogue in
/// CATALOGUE_DIR (catalog-v2.json, catalog.json) instead of Pocket's site, with its windows saved as pictures. For CI:
/// a catalogue's listings, descriptions, credits, links and favourites, seen in the real app on a real Mac.
///
/// It uses a throwaway library folder (never the user's own) and ends the app when done. Each SHOT is one of:
///   SECTION:ITEM          show a sidebar section (all, more, favourites, ...) with an item selected (cat:x, more:x)
///   favourite:ITEM        add ITEM to Favourites the way the app's buttons do, then show Favourites
///   about                 the About window
/// OUT_DIR gets one PNG per shot, and ui-snapshot.json with what each selected item showed.
enum UISnapshotConfig {
    static let args: [String]? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--ui-snapshot"), i + 2 < a.count else { return nil }
        return Array(a[(i + 1)...])
    }()
    static var enabled: Bool { args != nil }
    /// FM1_UI_LIBRARY keeps one library folder across runs (to see a favourite carry from one catalogue to the next)
    static let keep = ProcessInfo.processInfo.environment["FM1_UI_LIBRARY"]
    static let root: URL? = args == nil ? nil : keep.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("fm1-ui-snapshot-\(UUID().uuidString)", isDirectory: true)
    static var paths: LibraryPaths? { root.map { LibraryPaths(root: $0) } }
    static var base: URL? { args.map { URL(fileURLWithPath: $0[0], isDirectory: true) } }
}

@MainActor
enum UISnapshot {
    static func run(_ library: LibraryModel) async {
        guard let a = UISnapshotConfig.args else { return }
        let out = URL(fileURLWithPath: a[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // the catalogue read and the library shown (downloads may go on in the background; they are not waited for)
        for _ in 0..<600 where library.items.isEmpty || library.isRefreshing { try? await Task.sleep(nanoseconds: 100_000_000) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var log: [[String: Any]] = []
        for (n, shot) in a.dropFirst(2).enumerated() {
            let name = String(format: "%02d-", n + 1) + shot.replacingOccurrences(of: ":", with: "_")
            var r: [String: Any] = ["shot": shot]
            if shot == "about" {
                AboutPanel.show(attribution: library.attribution, editor: library.editorSource)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let panel = NSApp.windows.first { $0.isVisible && $0.className.contains("About") }
                    ?? NSApp.windows.first { $0.isVisible && $0.title.isEmpty && $0 is NSPanel }
                r["saved"] = panel.map { save($0, out.appendingPathComponent(name + ".png")) } ?? false
                panel?.close()
            } else {
                let parts = shot.split(separator: ":", maxSplits: 1).map(String.init)
                var id = parts.count > 1 ? parts[1] : nil
                if parts[0] == "favourite", let fid = id {
                    if let it = library.item(fid), !library.isFavourite(it) { library.toggleFavourite(it) }
                    library.section = SidebarItem(key: "favourites")
                    r["favourites"] = library.visible.map(\.id)
                } else {
                    library.section = SidebarItem(key: parts[0])
                }
                if id == nil { id = library.visible.first?.id }
                library.select(id)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let it = library.item(id) {
                    r["item"] = ["id": it.id, "name": it.name, "category": it.category, "listedOnly": it.isListedOnly,
                                 "compatibility": it.compatibilityText, "about": it.about,
                                 "description": it.attributed?.text ?? "", "descriptionCredit": it.attributed?.credit ?? "",
                                 "descriptionLicence": it.attributed?.license ?? "", "editorURL": it.editorURL ?? "",
                                 "hubURL": it.hubURL ?? "", "sourceURL": it.sourceURL ?? "", "favourite": library.isFavourite(it),
                                 "engine": it.engine, "canPlay": it.canPlay] as [String: Any]
                }
                r["section"] = parts[0]
                r["count"] = library.visible.count
                let w = NSApp.windows.first { $0.isVisible && $0.title == "FM-1 Pocket" }
                r["saved"] = w.map { save($0, out.appendingPathComponent(name + ".png")) } ?? false
            }
            log.append(r)
        }
        let summary: [String: Any] = ["items": library.items.count, "more": library.moreItems.count, "shots": log]
        if let d = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: out.appendingPathComponent("ui-snapshot.json"))
        }
        if UISnapshotConfig.keep == nil, let r = UISnapshotConfig.root { try? FileManager.default.removeItem(at: r) }
        NSApp.terminate(nil)
    }

    /// the window as drawn by the app itself (its own pixels: no screen-recording permission involved)
    static func save(_ w: NSWindow, _ url: URL) -> Bool {
        guard let v = w.contentView?.superview ?? w.contentView else { return false }
        let r = v.bounds
        guard let rep = v.bitmapImageRepForCachingDisplay(in: r) else { return false }
        v.cacheDisplay(in: r, to: rep)
        guard let d = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? d.write(to: url)) != nil
    }
}
