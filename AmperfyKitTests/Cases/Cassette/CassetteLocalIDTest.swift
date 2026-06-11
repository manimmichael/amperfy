//
//  CassetteLocalIDTest.swift
//  AmperfyKitTests
//
//  Cassette fork — Layer 1 (Identity) parity test.
//
//  Asserts the Swift CassetteLocalID port produces, for every vector, the same
//  id that the Go sidecar (apps/cassette-player/sidecar/local_id_test.go) and
//  the TypeScript web impl assert against.
//
//  CONTRACT: the vectors below are a verbatim copy of the locked fixture at
//  apps/cassette/test/fixtures/local-id-vectors.json. The iOS test bundle has
//  no access to that file at runtime (it lives in the web app, outside this
//  Xcode project), so the JSON is embedded here. If the canonical fixture
//  changes, copy it here verbatim and re-run — the two MUST stay identical.
//

@testable import AmperfyKit
import XCTest

class CassetteLocalIDTest: XCTestCase {
  /// Verbatim copy of apps/cassette/test/fixtures/local-id-vectors.json.
  private static let fixtureJSON = """
  [
    {
      "name": "ascii baseline",
      "artist": "Bon Iver",
      "title": "Day One",
      "duration_seconds": 184,
      "expected_local_id": "f9fb3ba93022d599de45fc3016168ee1"
    },
    {
      "name": "diacritic strip",
      "artist": "Sigur Rós",
      "title": "Glósóli",
      "duration_seconds": 372,
      "expected_local_id": "4cb557cb6f7c6c4a10d6b9e7d3ffe59b"
    },
    {
      "name": "whitespace collapse",
      "artist": "  Bon   Iver  ",
      "title": "Day  One",
      "duration_seconds": 184,
      "expected_local_id": "f9fb3ba93022d599de45fc3016168ee1"
    },
    {
      "name": "case insensitive",
      "artist": "BON IVER",
      "title": "day one",
      "duration_seconds": 184,
      "expected_local_id": "f9fb3ba93022d599de45fc3016168ee1"
    },
    {
      "name": "duration rounding down",
      "artist": "Bon Iver",
      "title": "Day One",
      "duration_seconds": 184.4,
      "expected_local_id": "f9fb3ba93022d599de45fc3016168ee1"
    },
    {
      "name": "duration rounding up",
      "artist": "Bon Iver",
      "title": "Day One",
      "duration_seconds": 184.5,
      "expected_local_id": "5b831cbfa09a67ad6e5b100bdb47ac3b"
    },
    {
      "name": "unicode nfkc fullwidth",
      "artist": "ＦＯＮＴＡＩＮＥＳ Ｄ.Ｃ.",
      "title": "Romance",
      "duration_seconds": 200,
      "expected_local_id": "8236342b131ab02b2a8ebcfd95d50c55"
    },
    {
      "name": "empty title",
      "artist": "Various",
      "title": "",
      "duration_seconds": 1,
      "expected_local_id": "6d68c305ff4f2f73fcd1eea46a356b27"
    },
    {
      "name": "empty artist and title",
      "artist": "",
      "title": "",
      "duration_seconds": 0,
      "expected_local_id": "7d4a8d99d1d2920565f89a68db351172"
    },
    {
      "name": "long unicode title",
      "artist": "Björk",
      "title": "Jóga (Strings & Vocal)",
      "duration_seconds": 308,
      "expected_local_id": "c6361ef0692d0a6f3bae5f05a1425968"
    },
    {
      "name": "pipe and separator chars",
      "artist": "AC/DC",
      "title": "Touch Too Much",
      "duration_seconds": 269,
      "expected_local_id": "6f0429f8367668526a32524e8e05e45d"
    },
    {
      "name": "negative duration treated as 0",
      "artist": "Test",
      "title": "Test",
      "duration_seconds": -10,
      "expected_local_id": "68b14e11af6d15e022daacbcccf0b4d0"
    },
    {
      "name": "null duration treated as 0",
      "artist": "Test",
      "title": "Test",
      "duration_seconds": null,
      "expected_local_id": "68b14e11af6d15e022daacbcccf0b4d0"
    }
  ]
  """

  private struct Vector: Decodable {
    let name: String
    let artist: String
    let title: String
    let durationSeconds: Double?
    let expectedLocalID: String

    enum CodingKeys: String, CodingKey {
      case name
      case artist
      case title
      case durationSeconds = "duration_seconds"
      case expectedLocalID = "expected_local_id"
    }
  }

  private func loadVectors() throws -> [Vector] {
    let data = Data(Self.fixtureJSON.utf8)
    let vectors = try JSONDecoder().decode([Vector].self, from: data)
    XCTAssertFalse(vectors.isEmpty, "fixture has no vectors")
    return vectors
  }

  func testFixtureVectors() throws {
    for v in try loadVectors() {
      // A nil/null duration is sent as NaN, which the algorithm guards to "0",
      // matching the Go (math.IsNaN → "0") and TS (!isFinite → "0") behaviour.
      let duration = v.durationSeconds ?? Double.nan
      let got = CassetteLocalID.compute(
        artist: v.artist,
        title: v.title,
        durationSeconds: duration
      )
      XCTAssertEqual(
        got,
        v.expectedLocalID,
        "vector \"\(v.name)\": compute(\(v.artist), \(v.title), \(String(describing: v.durationSeconds))) = \(got); want \(v.expectedLocalID)"
      )
    }
  }

  func testIntAndDoubleHelpersAgree() {
    let a = CassetteLocalID.compute(artist: "Bon Iver", title: "Day One", durationSeconds: 184.0)
    let b = CassetteLocalID.compute(artist: "Bon Iver", title: "Day One", durationSeconds: 184)
    XCTAssertEqual(a, b, "Double and Int helpers must agree")
  }

  func testOutputShapeIs32LowercaseHex() {
    let id = CassetteLocalID.compute(artist: "X", title: "Y", durationSeconds: 1)
    XCTAssertEqual(id.count, 32, "expected 32-char output, got \(id.count) (\(id))")
    let hexChars = Set("0123456789abcdef")
    for ch in id {
      XCTAssertTrue(hexChars.contains(ch), "non-hex char \(ch) in output \(id)")
    }
  }
}
