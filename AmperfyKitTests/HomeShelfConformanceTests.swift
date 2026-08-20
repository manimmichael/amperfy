//
//  HomeShelfConformanceTests.swift
//  AmperfyKitTests
//
//  iOS joins the cross-platform tripwire: feed every golden fixture's `input` to
//  the Swift engine and assert it produces the fixture's `expected` — the exact
//  same output the web engine produces. If this goes red, iOS has drifted from the
//  shared home-shelf algorithm (or the fixtures changed and iOS wasn't updated).
//
//  Setup (one-time, in Xcode): add this file AND home-shelves-fixtures.json to the
//  AmperfyKitTests target. The JSON must be in the test target's "Copy Bundle
//  Resources" build phase so `Bundle(for:)` can find it. Keep the JSON byte-
//  identical to apps/cassette/src/lib/home-shelves/fixtures.json (the canonical).
//

import XCTest
@testable import AmperfyKit

final class HomeShelfConformanceTests: XCTestCase {

  private struct Fixtures: Codable {
    let contractVersion: Int
    let scenarios: [Scenario]
    struct Scenario: Codable {
      let name: String
      let input: ShelfInput
      let expected: HomeShelves
    }
  }

  private func loadFixtures() throws -> Fixtures {
    let bundle = Bundle(for: type(of: self))
    guard let url = bundle.url(forResource: "home-shelves-fixtures", withExtension: "json") else {
      XCTFail("home-shelves-fixtures.json not in the test bundle — add it to AmperfyKitTests → Copy Bundle Resources")
      throw NSError(domain: "HomeShelfConformance", code: 1)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Fixtures.self, from: data)
  }

  func testContractShape() throws {
    let fixtures = try loadFixtures()
    XCTAssertEqual(fixtures.contractVersion, 1, "fixture contract version this engine understands")
    XCTAssertGreaterThanOrEqual(fixtures.scenarios.count, 4, "expected the full scenario set")
  }

  func testConformsToEveryScenario() throws {
    let fixtures = try loadFixtures()
    for scenario in fixtures.scenarios {
      let got = buildHomeShelves(scenario.input)
      XCTAssertEqual(
        got, scenario.expected,
        "\"\(scenario.name)\" drifted from the web golden fixture. If this is an " +
        "intentional algorithm change, regenerate fixtures.json and update every platform."
      )
    }
  }
}
