import Foundation

/// Each firmware's saved settings (its flash image), kept apart by firmware id and version:
/// `<folder>/<id>/<version>.flash`. A write goes to a temporary file first and keeps the previous image as
/// `.prev`, so a crash mid-write never loses the last good state.
public final class StateStore {
    public let folder: URL

    public init(folder: URL = PocketPaths.appSupport.appendingPathComponent("State", isDirectory: true)) {
        self.folder = folder
    }

    private static func safe(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+"))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    public func url(id: String, version: String) -> URL {
        folder.appendingPathComponent(Self.safe(id), isDirectory: true)
            .appendingPathComponent(Self.safe(version.isEmpty ? "unversioned" : version) + ".flash")
    }

    public func load(id: String, version: String) -> Data? {
        let u = url(id: id, version: version)
        if let d = try? Data(contentsOf: u), !d.isEmpty { return d }
        if let d = try? Data(contentsOf: u.appendingPathExtension("prev")), !d.isEmpty { return d }
        return nil
    }

    public func save(_ data: Data, id: String, version: String) throws {
        let u = url(id: id, version: version)
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
