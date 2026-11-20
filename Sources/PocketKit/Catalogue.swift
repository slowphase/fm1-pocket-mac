import Foundation

/// FM-1 Pocket Player's published catalogue (`data/catalog.json`, schema 1), built nightly by its `pocket/catalog.mjs`.
public struct Catalogue: Codable, Equatable {
    public var schema: Int
    public var updated: String
    public var since: String?
    public var count: Int?
    public var firmwares: [CatalogueEntry]

    public static func decode(_ data: Data) throws -> Catalogue {
        let c: Catalogue
        do { c = try JSONDecoder().decode(Catalogue.self, from: data) } catch { throw PocketError.badCatalogue("\(error)") }
        guard c.schema == 1 else { throw PocketError.badCatalogue("unknown catalogue schema \(c.schema)") }
        return c
    }
}

/// One firmware in the catalogue. Missing optional fields get sensible defaults, so a new field upstream never breaks us.
public struct CatalogueEntry: Codable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var authors: [String]
    public var category: String
    public var tag: String
    public var about: String
    public var license: String
    public var source: String?
    public var commit: String?
    public var glue: String?
    public var builtBy: String?
    public var abi: Int?
    public var beta: Bool
    /// relative to the catalogue's folder, e.g. `fw/amb-8a5014a6.rfm1`
    public var file: String
    public var sha256: String
    public var size: Int
    public var added: String?
    public var updated: String?
    /// relative to the catalogue's folder, e.g. `shots/amb-8a5014a6.png`
    public var image: String?
    /// For an original package (an id ending in `.fwsc`, from catalog-v2.json's emu block): the maker's own release
    /// asset, downloaded from there (The Firmware Hub's rule) and checked against `sha256`; `file` is then only its name.
    public var remoteURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, version, authors, category, tag, about, license, source, commit, glue, builtBy, abi, beta, file,
             sha256, size, added, updated, image, remoteURL
    }

    /// the suffix of a package variant's id: `felucca.fwsc` is felucca's original package
    public static let packageSuffix = ".fwsc"
    public var isPackage: Bool { id.hasSuffix(Self.packageSuffix) }
    /// the firmware's own id (without `.fwsc`)
    public var baseID: String { isPackage ? String(id.dropLast(Self.packageSuffix.count)) : id }
    /// the maker's URL for a package, when it is a plain https URL on GitHub (where makers release)
    public var makerURL: URL? {
        guard let s = remoteURL, let u = URL(string: s), u.scheme == "https",
              let h = u.host?.lowercased(), h == "github.com" || h.hasSuffix(".githubusercontent.com") else { return nil }
        return u
    }

    public init(id: String, name: String, version: String, authors: [String] = [], category: String = "Other",
                tag: String = "", about: String = "", license: String, source: String? = nil, commit: String? = nil,
                glue: String? = nil, builtBy: String? = nil, abi: Int? = nil, beta: Bool = false, file: String,
                sha256: String, size: Int, added: String? = nil, updated: String? = nil, image: String? = nil, remoteURL: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.authors = authors; self.category = category
        self.tag = tag; self.about = about; self.license = license; self.source = source; self.commit = commit
        self.glue = glue; self.builtBy = builtBy; self.abi = abi; self.beta = beta; self.file = file
        self.sha256 = sha256; self.size = size; self.added = added; self.updated = updated; self.image = image
        self.remoteURL = remoteURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        glue = try c.decodeIfPresent(String.self, forKey: .glue)
        builtBy = try c.decodeIfPresent(String.self, forKey: .builtBy)
        abi = try c.decodeIfPresent(Int.self, forKey: .abi)
        beta = try c.decodeIfPresent(Bool.self, forKey: .beta) ?? false
        file = try c.decode(String.self, forKey: .file)
        sha256 = try c.decode(String.self, forKey: .sha256).lowercased()
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        added = try c.decodeIfPresent(String.self, forKey: .added)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL)
    }

    public var authorLine: String { authors.joined(separator: ", ") }
}

public enum PocketError: LocalizedError, Equatable {
    case badCatalogue(String)
    case http(Int, String)
    case checksumMismatch(String)
    case badFirmware(String)

    public var errorDescription: String? {
        switch self {
        case .badCatalogue(let why): return "The firmware catalogue could not be read (\(why))."
        case .http(let code, let what): return "Could not download \(what) (HTTP \(code))."
        case .checksumMismatch(let name): return "\(name): the downloaded file does not match the catalogue, so it was not used."
        case .badFirmware(let why): return why
        }
    }
}
