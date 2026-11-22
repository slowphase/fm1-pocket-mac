import Foundation
import XCTest
@testable import PocketKit

final class QualificationTests: XCTestCase {
    private let sha = String(repeating: "a", count: 64)

    private func entry(_ qualification: [String: Any]) throws -> CatalogueV2.Entry {
        let f: [String: Any] = ["id": "sample", "name": "Sample", "version": "1", "license": "MIT",
            "file": "fw/sample.rfm1", "sha256": sha, "size": 1,
            "status": ["mac": ["state": "playable"]], "qualification": ["mac": qualification]]
        let raw = try JSONSerialization.data(withJSONObject: ["schema": 2, "snapshot": "2026-11-23", "updated": "2026-11-23", "firmwares": [f]])
        return try CatalogueV2.decode(raw).firmwares[0]
    }

    func testRfmOnlyQualificationDecodesWithoutOriginalPackage() throws {
        let f = try entry(["visible": true, "engines": ["rfm1"], "routes": [
            "rfm1": ["eligible": true, "sha256": sha],
            "fm1-emu": ["eligible": false, "status": ["state": "unavailable"]]]])
        XCTAssertTrue(f.qualifiesMac(engine: "rfm1"))
        XCTAssertFalse(f.qualifiesMac(engine: "fm1-emu"))
    }

    func testMalformedAndWrongFingerprintDecisionsFailClosed() throws {
        let malformed = try entry(["visible": true, "engines": ["rfm1"]])
        XCTAssertTrue(malformed.hasQualification)
        XCTAssertFalse(malformed.qualifiesMac(engine: "rfm1"))
        let stale = try entry(["visible": true, "engines": ["rfm1"], "routes": [
            "rfm1": ["eligible": true, "sha256": String(repeating: "b", count: 64)]]])
        XCTAssertFalse(stale.qualifiesMac(engine: "rfm1"))
    }

    func testHidingDoesNotRemoveInternalDownloadRecord() throws {
        let hidden = try entry(["visible": false, "engines": [], "routes": ["rfm1": ["eligible": false, "sha256": sha]]])
        XCTAssertNotNil(hidden.download)
        XCTAssertTrue(hidden.macDownloadable)
        XCTAssertFalse(hidden.qualifiesMac(engine: "rfm1"))
        XCTAssertEqual(hidden.id, "sample")
    }
}
