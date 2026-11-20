import CoreGraphics
import Foundation
import ImageIO

/// Search as FM-1 Pocket Player's picker does it: every word must appear somewhere in the firmware's text, and
/// punctuation is ignored, so "kwa" finds K-WA SUB and "fm1" finds FM-1. Names that match come first.
/// One addition to Pocket's rules: "!" counts as an "i", so "grimm" finds GR!MM.
public enum LibrarySearch {
    static func bare(_ s: String) -> String {
        String(s.lowercased().replacingOccurrences(of: "!", with: "i").unicodeScalars
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
    }

    public static func matches(_ query: String, fields: [String]) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        let hay = fields.joined(separator: " ").lowercased()
        let bareHay = bare(hay)
        return words.allSatisfy { w in
            let b = bare(w)
            return hay.contains(w) || (!b.isEmpty && bareHay.contains(b))
        }
    }

    /// 0: the name starts with the query, 1: the name contains it, 2: something else matched
    public static func rank(name: String, query: String) -> Int {
        let n = bare(name), q = bare(query)
        guard !q.isEmpty else { return 2 }
        if n.hasPrefix(q) { return 0 }
        return n.contains(q) ? 1 : 2
    }
}

/// Pocket's "new" badge: added to the catalogue within the last 14 days, and not part of the first catalogue.
public enum NewBadge {
    public static let days = 14

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func date(_ day: String?) -> Date? { day.flatMap { dayFormat.date(from: String($0.prefix(10))) } }

    /// "New to Library": it first appeared in the library (the day The Firmware Hub added it, or the day Pocket first
    /// saw it) within the last 14 days. Not a release date: a new release of an old firmware is not new to the library.
    public static func isNew(listed: String?, now: Date = Date()) -> Bool {
        guard let d = date(listed) else { return false }
        return now.timeIntervalSince(d) / 86400 <= Double(days)
    }
}

/// Recently played firmware (user-owned: `UserData/recent.json`), newest first, at most 25.
public struct RecentStore {
    public static let limit = 25
    public let file: URL

    private struct Item: Codable { var id: String; var playedAt: Date }

    public init(paths: LibraryPaths = LibraryPaths()) { file = paths.userData.appendingPathComponent("recent.json") }

    /// firmware id -> when it was last played
    public func load() -> [String: Date] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: file), let items = try? dec.decode([Item].self, from: d) else { return [:] }
        return Dictionary(items.map { ($0.id, $0.playedAt) }, uniquingKeysWith: { a, b in max(a, b) })
    }

    @discardableResult
    public func note(_ id: String, at date: Date = Date()) throws -> [String: Date] {
        var all = load()
        all[id] = date
        let kept = all.sorted { $0.value > $1.value }.prefix(Self.limit)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(kept.map { Item(id: $0.key, playedAt: $0.value) }).write(to: file, options: .atomic)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

/// Makes a screenshot for firmware the catalogue has no picture of (the built-in h1, imports), the way Pocket's
/// pipeline makes its own: boot fresh, run six seconds of device time (past any splash screen), take the screen.
public enum ScreenshotMaker {
    public static let milliseconds = 6000

    /// a 240x240 PNG of the firmware's screen, or nil if it stopped or drew nothing
    public static func png(for bytes: Data, milliseconds: Int = ScreenshotMaker.milliseconds) -> Data? {
        guard let core = try? FirmwareCore(bytes: bytes) else { return nil }
        core.boot(flash: nil)
        core.run(milliseconds: milliseconds)
        guard !core.isHalted else { return nil }
        var px: [UInt8] = []
        core.screen(into: &px)
        var lit = false
        for i in stride(from: 0, to: px.count, by: 4) where px[i] | px[i + 1] | px[i + 2] != 0 { lit = true; break }
        guard lit, let image = cgImage(px) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The cached screenshot for these bytes (`Managed/generated/<sha>.png`), made on first request. Slow the first
    /// time (it runs the firmware), so call it off the main thread.
    public static func cachedScreenshot(for bytes: Data, paths: LibraryPaths) -> URL? {
        let u = paths.generated.appendingPathComponent(String(sha256Hex(bytes).prefix(16)) + ".png")
        if FileManager.default.fileExists(atPath: u.path) { return u }
        guard let png = png(for: bytes) else { return nil }
        do {
            try FileManager.default.createDirectory(at: paths.generated, withIntermediateDirectories: true)
            try png.write(to: u, options: .atomic)
            return u
        } catch {
            return nil
        }
    }

    static func cgImage(_ rgba: [UInt8]) -> CGImage? {
        let n = FirmwareCore.screenSize
        guard rgba.count == n * n * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
