// A local preview of the actual catalogue decoder, library snapshot and UI merge.
// No firmware executes; all writes are confined to the supplied temporary root.
import Foundation
import PocketKit

@main
struct QualificationPreview {
    @MainActor
    static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        let expected = ((report["counts"] as! [String: Any])["mac"] as! [String: Any])["visibleIDs"] as! [String]
        let paths = LibraryPaths(root: URL(fileURLWithPath: CommandLine.arguments[3]))
        try FileManager.default.createDirectory(at: paths.managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.userData, withIntermediateDirectories: true)
        let marker = paths.userData.appendingPathComponent("favourites.json")
        let favourites = Data("[\"shifl\",\"noizdemons\"]".utf8)
        try favourites.write(to: marker)
        try data.write(to: paths.managed.appendingPathComponent("catalog-v2.json"))
        let library = FirmwareLibrary(paths: paths)
        let snap = await library.snapshot()
        let merged = LibraryModel.merged(snap, choices: [:], base: CatalogueService.defaultBase, paths: paths, builtin: nil)
        let actual = merged.items.map { String($0.id.dropFirst("cat:".count)) }.sorted()
        if actual != expected {
            let difference = "Unexpected: \(Set(actual).subtracting(expected).sorted()); missing: \(Set(expected).subtracting(actual).sorted())\n"
            FileHandle.standardError.write(Data(difference.utf8))
        }
        precondition(actual == expected, "Mac consumer/report disagreement")
        precondition(!actual.contains("sloop") && !actual.contains("araminta") && !actual.contains("shifl"))
        let savedFavourites = try Data(contentsOf: marker)
        precondition(savedFavourites == favourites, "Hiding must preserve stored favourites")
        let decoded = try CatalogueV2.decode(data)
        precondition(decoded.firmwares.count == report["internalRecords"] as! Int, "Hidden internal records must be retained")
        print("Mac preview passed: \(actual.count) visible; all \(decoded.firmwares.count) internal records retained; favourites unchanged.")
    }
}
