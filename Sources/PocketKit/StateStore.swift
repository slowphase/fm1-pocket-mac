import Foundation

/// Each firmware's saved settings (its flash image). User-owned: library sync and cleanup never touch this folder.
///
/// Saves are kept apart by firmware id and by **build**: `<folder>/<id>/<version>@<sha256 prefix>.flash`. The
/// content hash is part of the key because an author can rebuild a firmware without changing its version string,
/// and a rebuild may store its settings differently. (The older `load/save(id:version:)` form, keyed by version
/// alone, is kept for compatibility.)
///
/// A write goes to a temporary file first and keeps the previous image as `.prev`, so a crash mid-write never loses
/// the last good state. Saves are never deleted, moved or copied between builds automatically.
public final class StateStore {
    public let folder: URL

    public init(folder: URL = PocketPaths.appSupport.appendingPathComponent("State", isDirectory: true)) {
        self.folder = folder
    }

    static func safe(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+"))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    /// the name a build's save goes under: `<version>@<first 12 hex digits of its SHA-256>`
    public static func buildKey(version: String, sha256: String) -> String {
        safe(version.isEmpty ? "unversioned" : version) + "@" + String(sha256.lowercased().prefix(12))
    }

    private func dir(_ id: String) -> URL { folder.appendingPathComponent(Self.safe(id), isDirectory: true) }

    public func url(id: String, version: String) -> URL {
        dir(id).appendingPathComponent(Self.safe(version.isEmpty ? "unversioned" : version) + ".flash")
    }
    public func url(id: String, version: String, sha256: String) -> URL {
        dir(id).appendingPathComponent(Self.buildKey(version: version, sha256: sha256) + ".flash")
    }

    public func load(id: String, version: String) -> Data? { load(url(id: id, version: version)) }
    public func load(id: String, version: String, sha256: String) -> Data? { load(url(id: id, version: version, sha256: sha256)) }
    public func save(_ data: Data, id: String, version: String) throws { try save(data, to: url(id: id, version: version)) }
    public func save(_ data: Data, id: String, version: String, sha256: String) throws {
        try save(data, to: url(id: id, version: version, sha256: sha256))
    }

    /// The keys of every save this firmware has (build keys, or bare versions from the older form), newest first.
    public func savedKeys(id: String) -> [String] {
        let d = dir(id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        let files = names.filter { $0.hasSuffix(".flash") }
        func date(_ n: String) -> Date {
            (try? d.appendingPathComponent(n).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.sorted { date($0) > date($1) }.map { String($0.dropLast(6)) }
    }

    /// a save by its key (as `savedKeys` lists them)
    public func load(id: String, key: String) -> Data? {
        guard !key.isEmpty, !key.contains("/"), !key.hasPrefix(".") else { return nil }
        return load(dir(id).appendingPathComponent(key + ".flash"))
    }

    /// Deletes this build's save and its backup. Only for an explicit request ("Erase Saved Settings").
    public func erase(id: String, version: String, sha256: String) throws {
        let u = url(id: id, version: version, sha256: sha256)
        let fm = FileManager.default
        for f in [u, u.appendingPathExtension("prev")] where fm.fileExists(atPath: f.path) { try fm.removeItem(at: f) }
    }

    /// The save, or its backup when the save itself is missing or unreadable. A save that exists but is empty is
    /// a real save (the emulator engine's "nothing differs from the package"): it is not replaced by an older backup.
    private func load(_ u: URL) -> Data? {
        if let d = try? Data(contentsOf: u) { return d.isEmpty ? nil : d }
        if let d = try? Data(contentsOf: u.appendingPathExtension("prev")), !d.isEmpty { return d }
        return nil
    }

    private func save(_ data: Data, to u: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let old = try? Data(contentsOf: u), old == data { return }
        let prev = u.appendingPathExtension("prev")
        if fm.fileExists(atPath: u.path) {
            try? fm.removeItem(at: prev)
            try? fm.copyItem(at: u, to: prev)
        }
        try data.write(to: u, options: .atomic)
    }
}
