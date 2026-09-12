//
//  UtilitiesTest.swift
//  AmperfyKitTests
//
//  Created by Maximilian Bauer on 09.05.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

@testable import AmperfyKit
import XCTest

class UtilitiesTest: XCTestCase {
  func testInt16Valid() {
    XCTAssertTrue(Int16.isValid(value: Int(Int16.max)))
    XCTAssertTrue(Int16.isValid(value: Int(Int16.min)))
    XCTAssertTrue(Int16.isValid(value: Int(0)))
    XCTAssertTrue(Int16.isValid(value: Int(Int16.min) + 1))
    XCTAssertTrue(Int16.isValid(value: Int(Int16.max) - 1))
  }

  func testInt16Invalid() {
    XCTAssertFalse(Int16.isValid(value: Int(Int16.max) + 1))
    XCTAssertFalse(Int16.isValid(value: Int(Int16.min) - 1))
    XCTAssertFalse(Int16.isValid(value: Int(Int32.min)))
    XCTAssertFalse(Int16.isValid(value: Int(Int32.max)))
  }

  func testInt32Valid() {
    XCTAssertTrue(Int32.isValid(value: Int(Int32.max)))
    XCTAssertTrue(Int32.isValid(value: Int(Int32.min)))
    XCTAssertTrue(Int32.isValid(value: Int(0)))
    XCTAssertTrue(Int32.isValid(value: Int(Int32.min + 1)))
    XCTAssertTrue(Int32.isValid(value: Int(Int32.max - 1)))
  }

  func testInt32Invalid() {
    XCTAssertFalse(Int32.isValid(value: Int(Int32.max) + 1))
    XCTAssertFalse(Int32.isValid(value: Int(Int32.min) - 1))
    XCTAssertFalse(Int32.isValid(value: Int(Int64.min)))
    XCTAssertFalse(Int32.isValid(value: Int(Int64.max)))
  }

  // MARK: - CarPlay alphabetic bucketing (cassette, BUG-337)

  private static func fixture(_ pairs: [(String, Int)]) -> [AlphabeticSectionCount] {
    pairs.map { AlphabeticSectionCount(name: $0.0, count: $0.1) }
  }

  private static let l30: [AlphabeticSectionCount] = fixture([
    ("#", 2), ("A", 3), ("B", 4), ("C", 2), ("D", 3), ("F", 1), ("H", 2),
    ("L", 2), ("M", 3), ("N", 1), ("P", 2), ("R", 1), ("S", 3), ("T", 1),
  ])

  private static let l120: [AlphabeticSectionCount] = fixture([
    ("#", 3), ("A", 8), ("B", 10), ("C", 7), ("D", 6), ("E", 3), ("F", 4), ("G", 3),
    ("H", 5), ("I", 2), ("J", 3), ("K", 2), ("L", 5), ("M", 9), ("N", 3), ("O", 2),
    ("P", 6), ("R", 5), ("S", 14), ("T", 12), ("U", 1), ("V", 2), ("W", 4), ("Y", 1),
  ])

  private static let l600: [AlphabeticSectionCount] = fixture([
    ("#", 12), ("A", 40), ("B", 45), ("C", 38), ("D", 30), ("E", 18), ("F", 22),
    ("G", 20), ("H", 25), ("I", 10), ("J", 15), ("K", 12), ("L", 28), ("M", 40),
    ("N", 16), ("O", 12), ("P", 30), ("Q", 3), ("R", 28), ("S", 60), ("T", 55),
    ("U", 6), ("V", 10), ("W", 20), ("X", 1), ("Y", 4),
  ])

  private static let spec: [AlphabeticSectionCount] = fixture([
    ("?", 1), ("&", 2), ("#", 3), ("A", 9), ("B", 8), ("C", 7),
  ])

  private static let the: [AlphabeticSectionCount] = fixture([
    ("A", 2), ("T", 40), ("Z", 1),
  ])

  private static let allFixtures: [[AlphabeticSectionCount]] = [l30, l120, l600, spec, the]

  private func pack(
    _ sections: [AlphabeticSectionCount],
    _ budget: Int,
    sectionBudget: Int = 50
  )
    -> [AlphabeticBucket] {
    AlphabeticBucketPacker.pack(
      sections: sections,
      itemBudget: budget,
      sectionBudget: sectionBudget
    )
  }

  private func labels(_ buckets: [AlphabeticBucket]) -> [String] {
    buckets.map { AlphabeticBucketPacker.label(for: $0) }
  }

  func testPackFlatWhenItFits() {
    XCTAssertEqual(pack(Self.l30, 100), [])
    XCTAssertEqual(pack(Self.l30, 500), [])
    XCTAssertEqual(pack(Self.l120, 500), [])
    XCTAssertEqual(pack(Self.l30, 30), [], "N == B is flat")
    XCTAssertFalse(pack(Self.l30, 29).isEmpty, "N == B + 1 is not flat")
  }

  func testPackL30At24() {
    let buckets = pack(Self.l30, 24)
    XCTAssertEqual(buckets.count, 2)
    XCTAssertEqual(buckets.map { $0.sectionNames }, [
      ["#", "A", "B", "C", "D", "F"],
      ["H", "L", "M", "N", "P", "R", "S", "T"],
    ])
    XCTAssertEqual(buckets.map { $0.itemCount }, [15, 15])
    XCTAssertEqual(labels(buckets), ["# - F", "H - T"])
    XCTAssertTrue(buckets.allSatisfy { !$0.isChunk })
  }

  func testPackL120At24() {
    let buckets = pack(Self.l120, 24)
    XCTAssertEqual(buckets.count, 6)
    XCTAssertEqual(buckets.map { $0.itemCount }, [21, 20, 20, 20, 19, 20])
    XCTAssertEqual(buckets.first?.sectionNames.first, "#")
    XCTAssertEqual(buckets.last?.sectionNames.last, "Y")
    XCTAssertEqual(labels(buckets), ["# - B", "C - F", "G - L", "M - P", "R - S", "T - Y"])
  }

  func testPackL120At100() {
    let buckets = pack(Self.l120, 100)
    XCTAssertEqual(buckets.map { $0.itemCount }, [61, 59])
    XCTAssertEqual(labels(buckets), ["# - L", "M - Y"])
  }

  func testPackL600At100() {
    let buckets = pack(Self.l600, 100)
    XCTAssertEqual(buckets.map { $0.itemCount }, [97, 86, 92, 96, 73, 60, 96])
    XCTAssertEqual(
      labels(buckets),
      ["# - B", "C - E", "F - J", "K - N", "O - R", "S", "T - Y"]
    )
  }

  func testPackL600At500() {
    let buckets = pack(Self.l600, 500)
    XCTAssertEqual(buckets.map { $0.itemCount }, [287, 313])
    XCTAssertEqual(labels(buckets), ["# - K", "L - Y"])
  }

  func testPackL600At24() {
    let buckets = pack(Self.l600, 24)
    XCTAssertEqual(buckets.count, 37)
    XCTAssertTrue(buckets.allSatisfy { $0.itemCount <= 24 })
    XCTAssertEqual(buckets.reduce(0) { $0 + $1.itemCount }, 600)

    func chunkCounts(_ name: String) -> [Int] {
      buckets.filter { $0.isChunk && $0.sectionNames == [name] }.map { $0.itemCount }
    }
    XCTAssertEqual(chunkCounts("S"), [20, 20, 20])
    XCTAssertEqual(chunkCounts("T"), [19, 18, 18])
    XCTAssertEqual(chunkCounts("H"), [13, 12])
    XCTAssertEqual(labels(buckets.filter { $0.sectionNames == ["S"] }), [
      "S (1 of 3)", "S (2 of 3)", "S (3 of 3)",
    ])
    XCTAssertEqual(labels(buckets.filter { $0.sectionNames.first == "U" }), ["U - V"])
    XCTAssertEqual(labels(buckets.filter { $0.sectionNames.first == "X" }), ["X - Y"])

    // Every section appears in exactly one whole bucket, or in exactly chunk.count chunk
    // buckets with consecutive indices.
    for section in Self.l600 {
      let whole = buckets.filter { !$0.isChunk && $0.sectionNames.contains(section.name) }
      let chunks = buckets.filter { $0.isChunk && $0.sectionNames == [section.name] }
      if whole.count == 1 {
        XCTAssertTrue(chunks.isEmpty, section.name)
      } else {
        XCTAssertTrue(whole.isEmpty, section.name)
        XCTAssertFalse(chunks.isEmpty, section.name)
        let planned = chunks.first?.chunk?.count ?? -1
        XCTAssertEqual(chunks.count, planned, section.name)
        XCTAssertEqual(chunks.map { $0.chunk?.index }, Array(0 ..< chunks.count), section.name)
        XCTAssertTrue(chunks.allSatisfy { $0.chunk?.count == planned }, section.name)
      }
    }
  }

  func testPackKeepsSpecialsContiguousAndLabelsCollapse() {
    XCTAssertEqual(labels(pack(Self.spec, 24)), ["# - A", "B - C"])
    XCTAssertEqual(pack(Self.spec, 24).map { $0.itemCount }, [15, 15])
    XCTAssertEqual(labels(pack(Self.spec, 12)), ["#", "A", "B", "C"])
    XCTAssertEqual(pack(Self.spec, 12).map { $0.itemCount }, [6, 9, 8, 7])
    XCTAssertEqual(pack(Self.spec, 24).first?.sectionNames, ["?", "&", "#", "A"])
    XCTAssertEqual(AlphabeticBucketPacker.displayKey("?"), "#")
    XCTAssertEqual(AlphabeticBucketPacker.displayKey("&"), "#")
    XCTAssertEqual(AlphabeticBucketPacker.displayKey("#"), "#")
    XCTAssertEqual(AlphabeticBucketPacker.displayKey("Q"), "Q")
    XCTAssertEqual(AlphabeticBucketPacker.displayKey("Qu"), "Q", "prefix(1) before comparing")
  }

  func testPackOversizedSingleLetter() {
    let buckets = pack(Self.the, 24)
    XCTAssertEqual(labels(buckets), ["A", "T (1 of 2)", "T (2 of 2)", "Z"])
    XCTAssertEqual(buckets.map { $0.itemCount }, [2, 20, 20, 1])
    XCTAssertEqual(buckets.map { $0.isChunk }, [false, true, true, false])
  }

  func testPackHonoursSectionBudget() {
    let buckets = pack(Self.l30, 100, sectionBudget: 3)
    XCTAssertEqual(buckets.count, 5)
    XCTAssertTrue(buckets.allSatisfy { $0.sectionNames.count <= 3 })
    XCTAssertEqual(buckets.map { $0.itemCount }, [9, 6, 7, 4, 4])
    XCTAssertEqual(labels(buckets), ["# - B", "C - F", "H - M", "N - R", "S - T"])
  }

  func testPackNeverExceedsBudget() {
    for fixture in Self.allFixtures {
      let total = fixture.reduce(0) { $0 + $1.count }
      let names = fixture.map { $0.name }
      for budget in 2 ... 40 {
        let buckets = pack(fixture, budget)
        if buckets.isEmpty {
          XCTAssertLessThanOrEqual(total, budget, "flat only when it fits (B=\(budget))")
          continue
        }
        XCTAssertTrue(
          buckets.allSatisfy { $0.itemCount <= budget },
          "bucket over budget at B=\(budget): \(buckets.map { $0.itemCount })"
        )
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.itemCount }, total, "sum at B=\(budget)")
        // Chunks collapsed: a section's chunk buckets count once, at chunk index 0.
        var covered = [String]()
        for bucket in buckets {
          if let chunk = bucket.chunk {
            if chunk.index == 0 { covered.append(contentsOf: bucket.sectionNames) }
          } else {
            covered.append(contentsOf: bucket.sectionNames)
          }
        }
        XCTAssertEqual(covered, names, "coverage at B=\(budget)")
      }
    }
  }

  func testChunkRange() {
    XCTAssertEqual(AlphabeticBucketPacker.chunkRange(count: 60, chunks: 3, index: 0), 0 ..< 20)
    XCTAssertEqual(AlphabeticBucketPacker.chunkRange(count: 60, chunks: 3, index: 1), 20 ..< 40)
    XCTAssertEqual(AlphabeticBucketPacker.chunkRange(count: 60, chunks: 3, index: 2), 40 ..< 60)
    XCTAssertNil(AlphabeticBucketPacker.chunkRange(count: 60, chunks: 3, index: 3))
    XCTAssertEqual(AlphabeticBucketPacker.chunkRange(count: 25, chunks: 2, index: 0), 0 ..< 13)
    XCTAssertEqual(AlphabeticBucketPacker.chunkRange(count: 25, chunks: 2, index: 1), 13 ..< 25)
    XCTAssertEqual(AlphabeticBucketPacker.chunkRange(count: 10, chunks: 1, index: 0), 0 ..< 10)
    XCTAssertNil(AlphabeticBucketPacker.chunkRange(count: 0, chunks: 2, index: 0))
    XCTAssertNil(AlphabeticBucketPacker.chunkRange(count: 10, chunks: 0, index: 0))
    // A letter that shrank below its planned chunk count yields empty trailing slices,
    // never a trap.
    XCTAssertEqual(AlphabeticBucketPacker.chunkRange(count: 2, chunks: 3, index: 2), 2 ..< 2)
  }

  func testPageBounds() {
    let p0 = AlphabeticBucketPacker.pageBounds(rowCount: 37, budget: 24, page: 0)
    XCTAssertEqual(p0.range, 0 ..< 23)
    XCTAssertEqual(p0.page, 0)
    XCTAssertEqual(p0.pageCount, 2)
    for page in [1, 2, 5] {
      let p = AlphabeticBucketPacker.pageBounds(rowCount: 37, budget: 24, page: page)
      XCTAssertEqual(p.range, 23 ..< 37, "page \(page)")
      XCTAssertEqual(p.page, 1, "page \(page)")
      XCTAssertEqual(p.pageCount, 2, "page \(page)")
    }
    let fits = AlphabeticBucketPacker.pageBounds(rowCount: 24, budget: 24, page: 0)
    XCTAssertEqual(fits.range, 0 ..< 24)
    XCTAssertEqual(fits.page, 0)
    XCTAssertEqual(fits.pageCount, 1)
    let sixty = (0 ..< 3)
      .map { AlphabeticBucketPacker.pageBounds(rowCount: 60, budget: 24, page: $0) }
    XCTAssertEqual(sixty.map { $0.range }, [0 ..< 23, 23 ..< 46, 46 ..< 60])
    XCTAssertEqual(sixty.map { $0.page }, [0, 1, 2])
    XCTAssertTrue(sixty.allSatisfy { $0.pageCount == 3 })
    let empty = AlphabeticBucketPacker.pageBounds(rowCount: 0, budget: 24, page: 0)
    XCTAssertEqual(empty.range, 0 ..< 0)
    XCTAssertEqual(empty.page, 0)
    XCTAssertEqual(empty.pageCount, 1)
  }

  func testPackEmptyInput() {
    for budget in [0, 1, 2, 24, 500] {
      XCTAssertEqual(pack([], budget), [])
      XCTAssertEqual(pack([], budget, sectionBudget: 0), [])
    }
    XCTAssertEqual(pack(Self.l30, 0, sectionBudget: 0).reduce(0) { $0 + $1.itemCount }, 30)
    XCTAssertEqual(pack(Self.l30, 24, sectionBudget: 0).reduce(0) { $0 + $1.itemCount }, 30)
  }
}
