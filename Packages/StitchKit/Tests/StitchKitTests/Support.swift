import CryptoKit
import Foundation
import Testing
@testable import StitchKit

enum Fixtures {
    static var directory: URL {
        get throws {
            guard let base = Bundle.module.resourceURL else {
                throw FixtureError.missingBundle
            }
            return base.appendingPathComponent("Fixtures", isDirectory: true)
        }
    }

    static func url(_ name: String) throws -> URL {
        let url = try directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.missingFixture(name)
        }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// Every generated fixture, in the order `make_fixtures.py` writes them.
    static let all = [
        "asymmetric.dst",
        "multicolor.dst",
        "huge.dst",
        "jumps.dst",
        "truncated.dst",
        "garbage-header.dst",
        "empty.dst"
    ]

    static var goldens: [String: Golden] {
        get throws {
            let data = try Data(contentsOf: url("reference-decode.json"))
            return try JSONDecoder().decode([String: Golden].self, from: data)
        }
    }
}

enum FixtureError: Error {
    case missingBundle
    case missingFixture(String)
}

/// One fixture's decode as produced by `Scripts/reference_decoder.py`.
struct Golden: Codable {
    var recordCount: Int
    var sha256: String
    var minX: Int?
    var maxX: Int?
    var minY: Int?
    var maxY: Int?
    var stitchCount: Int?
    var stitchMinX: Int?
    var stitchMaxX: Int?
    var stitchMinY: Int?
    var stitchMaxY: Int?
    /// Present only for fixtures small enough that a full diff stays readable.
    var records: [[Int]]?
}

extension Array where Element == DSTParser.Record {
    /// The same canonical serialization the Python reference hashes, so the comparison
    /// is byte-for-byte rather than approximate.
    var canonicalString: String {
        var out = ""
        out.reserveCapacity(count * 16)
        for record in self {
            out += "\(record.x),\(record.y),\(record.command)\n"
        }
        return out
    }

    var sha256: String {
        let digest = SHA256.hash(data: Data(canonicalString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
