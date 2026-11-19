import Foundation

/// The facts an .rfm1 carries about itself: its manifest (the `rfm1` custom section, JSON), its credits and the
/// licence texts (`rfm1.credits`, `rfm1.license.N`). Mirrors `parse()` in FM-1 Pocket Player's src/rfm1.js.
public struct RFM1File {
    public struct License: Equatable { public var name: String; public var text: String }

    public var id: String
    public var name: String
    public var version: String
    public var license: String
    public var sourceURL: String
    public var abi: Int
    public var authors: [String]
    public var credits: String
    public var licenses: [License]

    public init(_ bytes: Data) throws {
        let b = [UInt8](bytes)
        guard b.count >= 8, b[0] == 0, b[1] == 0x61, b[2] == 0x73, b[3] == 0x6d, b[4] == 1 else {
            throw PocketError.badFirmware("This is not a WebAssembly module, so it is not an .rfm1 file.")
        }
        var custom: [String: Data] = [:]
        var i = 8
        func leb() throws -> Int {
            var v = 0, shift = 0
            while true {
                guard i < b.count, shift < 35 else { throw PocketError.badFirmware("The file is damaged.") }
                let c = b[i]; i += 1
                v |= Int(c & 0x7f) << shift
                shift += 7
                if c & 0x80 == 0 { return v }
            }
        }
        while i < b.count {
            let id = b[i]; i += 1
            let size = try leb()
            let end = i + size
            guard end <= b.count else { throw PocketError.badFirmware("The file is damaged.") }
            if id == 0 {
                let n = try leb()
                guard i + n <= end else { throw PocketError.badFirmware("The file is damaged.") }
                let key = String(decoding: b[i..<(i + n)], as: UTF8.self)
                custom[key] = Data(b[(i + n)..<end])
            }
            i = end
        }
        guard let manifest = custom["rfm1"] else {
            throw PocketError.badFirmware("This WebAssembly module has no rfm1 manifest, so it is not an .rfm1 file.")
        }
        guard let m = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any] else {
            throw PocketError.badFirmware("The file's rfm1 manifest is not valid JSON.")
        }
        for k in ["rfm1", "abi", "id", "name", "version", "license", "source_url"] {
            let v = m[k]
            if v == nil || v is NSNull || (v as? String) == "" { throw PocketError.badFirmware("The manifest has no \(k).") }
        }
        guard (m["rfm1"] as? Int) == 1 else { throw PocketError.badFirmware("This .rfm1 version is not supported (this player reads version 1).") }
        func str(_ k: String) -> String { (m[k] as? String) ?? (m[k].map { "\($0)" } ?? "") }
        id = str("id"); name = str("name"); version = str("version"); license = str("license"); sourceURL = str("source_url")
        abi = (m["abi"] as? Int) ?? 0
        authors = (m["authors"] as? [String]) ?? []
        credits = custom["rfm1.credits"].map { String(decoding: $0, as: UTF8.self) } ?? ""
        var lic: [License] = []
        var j = 0
        while let t = custom["rfm1.license.\(j)"] {
            let s = String(decoding: t, as: UTF8.self)
            if let nl = s.firstIndex(of: "\n") { lic.append(License(name: String(s[..<nl]), text: String(s[s.index(after: nl)...]))) }
            else { lic.append(License(name: s, text: "")) }
            j += 1
        }
        licenses = lic
    }
}
